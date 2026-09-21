# Bazzite + open-vm-tools with a Wayland clipboard backend.
#
# Stage 1 rebuilds Fedora's open-vm-tools with every patch in patches/;
# stage 2 replaces the base image's copies with the rebuilt ones.
#
#   podman build -t bazzite-ovt .
#
# To add a patch: drop it in patches/. Nothing here needs editing -- the spec
# is rewritten from whatever the directory contains, in sorted order, so name
# files 0001-, 0002-, ... to control apply order.
#
# Both stages fail loudly rather than silently shipping something unpatched:
# the version guard catches a Fedora rebase, the strings check catches a build
# where autoreconf did not pick up the new sources.

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
ARG FEDORA_RELEASE=44
ARG OVT_VERSION=13.1.0

# ---------------------------------------------------------------------------
# Stage 1: build the patched RPMs
# ---------------------------------------------------------------------------
FROM registry.fedoraproject.org/fedora:${FEDORA_RELEASE} AS builder
ARG OVT_VERSION

RUN dnf install -y fedora-packager rpmdevtools 'dnf-command(builddep)' \
    && dnf clean all

RUN rpmdev-setuptree
WORKDIR /root/rpmbuild

# Kept in their own directory: SOURCES/ also receives Fedora's own patches
# from the src.rpm, and globbing there would re-register those.
COPY patches/ /patches/

# Fetch the distro source package.
RUN dnf download --source open-vm-tools --enablerepo='*-source' \
    && rpm -i open-vm-tools-*.src.rpm

# The patches are written against a specific upstream tree. If Fedora moves to
# a different version, stop here instead of producing a subtly broken build.
RUN set -eux; \
    spec=SPECS/open-vm-tools.spec; \
    got="$(sed -n 's|^Version:[[:space:]]*||p' "$spec" | head -1)"; \
    if [ "$got" != "${OVT_VERSION}" ]; then \
        echo "ERROR: expected open-vm-tools ${OVT_VERSION}, Fedora now ships $got." >&2; \
        echo "Re-verify the patches against $got before bumping OVT_VERSION." >&2; \
        exit 1; \
    fi

# Register every patch in SOURCES, numbered from 101 so they apply after
# Fedora's own. %autosetup -p1 applies them in numeric order and aborts the
# build if any fails.
#
# Fedora's spec uses %autorelease, which needs rpmautospec to expand and cannot
# simply be appended to, so the whole Release value is replaced. The high
# number keeps this sorting above whatever Fedora ships, which is what
# "rpm-ostree override replace" requires.
RUN set -eux; \
    spec=SPECS/open-vm-tools.spec; \
    cp /patches/*.patch SOURCES/; \
    n=101; \
    : > /tmp/patchlines; \
    for f in $(ls -1 /patches/*.patch | sort); do \
        printf 'Patch%d:         %s\n' "$n" "$(basename "$f")" >> /tmp/patchlines; \
        n=$((n+1)); \
    done; \
    test -s /tmp/patchlines; \
    anchor="$(grep -n '^Patch[0-9]\+:' "$spec" | tail -1 | cut -d: -f1)"; \
    if [ -z "$anchor" ]; then \
        anchor="$(( $(grep -n '^BuildRequires:' "$spec" | head -1 | cut -d: -f1) - 1 ))"; \
    fi; \
    sed -i "${anchor}r /tmp/patchlines" "$spec"; \
    sed -i -E 's|^Release:[[:space:]]*.*$|Release:          100%{?dist}.clipway|' "$spec"; \
    grep -qE '^Release:.*clipway' "$spec"; \
    echo "--- registered:"; \
    grep -nE '^(Release|Patch[0-9]+):' "$spec"

RUN dnf builddep -y SPECS/open-vm-tools.spec && dnf clean all
RUN rpmbuild -bb SPECS/open-vm-tools.spec

# Keep only the two subpackages we replace; the rest (devel, debuginfo, test,
# sdmp, salt-minion) are not installed in the base image and pulling them in
# would turn a replace into a layer.
RUN set -eux; \
    mkdir -p /rpms; \
    cp RPMS/x86_64/open-vm-tools-${OVT_VERSION}-*.clipway.*.rpm /rpms/; \
    cp RPMS/x86_64/open-vm-tools-desktop-${OVT_VERSION}-*.clipway.*.rpm /rpms/; \
    ls -1 /rpms

# Canary: the Wayland backend shells out to wl-clipboard, so these literals are
# present only if autoreconf regenerated the build with the new sources.
RUN set -eux; \
    cd "$(mktemp -d)"; \
    rpm2cpio /rpms/open-vm-tools-desktop-*.rpm | cpio -idm --quiet; \
    so=./usr/lib64/open-vm-tools/plugins/vmusr/libdndcp.so; \
    strings "$so" | grep -q 'wl-copy'; \
    strings "$so" | grep -q 'list-types'; \
    echo "patched dndcp verified"

# ---------------------------------------------------------------------------
# Stage 2: derive the Bazzite image
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}
ARG SIGNED_REPO=ghcr.io/goproslowyo/bazzite-ovt

COPY --from=builder /rpms /tmp/rpms

RUN set -eux; \
    rpm-ostree override replace \
        /tmp/rpms/open-vm-tools-[0-9]*.rpm \
        /tmp/rpms/open-vm-tools-desktop-[0-9]*.rpm; \
    rm -rf /tmp/rpms

# Signature verification for this image's own repo.
#
# The stock policy only verifies ghcr.io/ublue-os and some Red Hat sources, so
# without this an ostree-image-signed reference to our repo is refused. Note
# the bootstrap order: the policy lives inside the image, so a machine has to
# run the unsigned image once before it can switch to the signed reference.
COPY cosign.pub /etc/pki/containers/bazzite-ovt.pub

RUN set -eux; \
    policy=/etc/containers/policy.json; \
    test -f "$policy"; \
    tmp="$(mktemp)"; \
    jq --arg repo "${SIGNED_REPO}" \
       --arg key "/etc/pki/containers/bazzite-ovt.pub" \
       '.transports.docker[$repo] = [{ \
            "type": "sigstoreSigned", \
            "keyPath": $key, \
            "signedIdentity": { "type": "matchRepository" } \
        }]' "$policy" > "$tmp"; \
    cat "$tmp" > "$policy"; \
    rm -f "$tmp"; \
    jq -e --arg repo "${SIGNED_REPO}" '.transports.docker[$repo][0].keyPath' "$policy"

# Tell the containers stack to look for cosign-style signature attachments on
# this repo; without it the policy above has nothing to find.
RUN set -eux; \
    mkdir -p /etc/containers/registries.d; \
    printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' \
        "${SIGNED_REPO}" > /etc/containers/registries.d/bazzite-ovt.yaml; \
    cat /etc/containers/registries.d/bazzite-ovt.yaml

RUN ostree container commit
