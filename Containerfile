# Bazzite with open-vm-tools rebuilt for Wayland copy and paste and drag and
# drop.
#
# Stage 1 rebuilds Fedora's open-vm-tools with every patch in patches/, and
# stage 2 replaces the base image's copies with the rebuilt ones.
#
#   podman build -t bazzite-ovt .
#
# To add a patch, drop it in patches/. Nothing here needs editing. The spec is
# rewritten from whatever the directory contains, in sorted order, so name
# files 0001-, 0002-, ... to control apply order.
#
# Both stages fail rather than ship something unpatched. The version guard
# catches a Fedora rebase, and the strings check catches a build where
# autoreconf did not pick up the new sources.

ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
ARG FEDORA_RELEASE=44
ARG OVT_VERSION=13.1.0

# ---------------------------------------------------------------------------
# Stage 1: build the patched RPMs
# ---------------------------------------------------------------------------
FROM registry.fedoraproject.org/fedora:${FEDORA_RELEASE} AS builder
ARG OVT_VERSION
# Declared again. An ARG before the first FROM is global scope only, and the
# src.rpm signature check below needs the release to name Fedora's key.
ARG FEDORA_RELEASE

RUN dnf install -y fedora-packager rpmdevtools 'dnf-command(builddep)' \
    && dnf clean all

RUN rpmdev-setuptree
WORKDIR /root/rpmbuild

# Kept in their own directory. SOURCES/ also receives Fedora's own patches
# from the src.rpm, and globbing there would re-register those.
COPY patches/ /patches/

# Fetch the distro source package.
#
# Name the two source repos rather than globbing '*-source'. The glob also
# matches updates-testing-source, so the build could silently pick up an SRPM
# that has not passed Bodhi gating.
#
# dnf download is not a transaction and performs no OpenPGP check, and rpm's
# default _pkgverify_level is 'digest', so an unsigned or tampered src.rpm
# would install without complaint. This is the one input that becomes the
# shipped binary, so verify it against Fedora's key explicitly. Compare the
# whole line. An unsigned package prints "<name>: digests OK" and exits 0, so
# a substring match on the verdict can be satisfied by the file's name.
RUN set -eux; \
    dnf download --source open-vm-tools \
        --enablerepo=fedora-source --enablerepo=updates-source; \
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary; \
    set -- open-vm-tools-*.src.rpm; \
    test "$#" -eq 1 || { echo "ERROR: expected one src.rpm, got $#: $*" >&2; exit 1; }; \
    r="$1"; \
    case "$r" in \
        *[!A-Za-z0-9._+~^-]*) echo "ERROR: unexpected src.rpm name: $r" >&2; exit 1 ;; \
    esac; \
    out="$(rpmkeys --checksig "$r")"; \
    echo "$out"; \
    [ "$out" = "$r: digests signatures OK" ] || { \
        echo "ERROR: $r did not verify against a trusted key." >&2; \
        exit 1; \
    }; \
    rpm -i "$r"

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
#
# The patches generate their Wayland protocol code at build time. The spec
# gains the packages that needs, and --with-wayland makes configure fail
# rather than build a plugin without the Wayland backend if one is missing.
RUN set -eux; \
    export LC_ALL=C; \
    spec=SPECS/open-vm-tools.spec; \
    cp /patches/*.patch SOURCES/; \
    n=101; \
    : > /tmp/patchlines; \
    for f in /patches/*.patch; do \
        test -e "$f" || break; \
        b="$(basename "$f")"; \
        case "$b" in \
            *[!A-Za-z0-9._-]*|'') bad=1 ;; \
            *) bad=0 ;; \
        esac; \
        if [ "$bad" = 1 ] || ! printf '%s' "$b" | grep -qE '^[0-9]{4}-[A-Za-z0-9._-]+\.patch$'; then \
            echo "ERROR: refusing patch filename: $b" >&2; \
            echo "Patch filenames must match NNNN-<name>.patch with <name> in [A-Za-z0-9._-]." >&2; \
            echo "RPM expands macros inside tag values, so anything else can run shell at spec-parse time." >&2; \
            exit 1; \
        fi; \
        printf 'Patch%d:         %s\n' "$n" "$b" >> /tmp/patchlines; \
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
    sed -i '/^BuildRequires:[[:space:]]*pkgconfig(gtkmm-4.0)/a BuildRequires:    pkgconfig(wayland-client)\nBuildRequires:    pkgconfig(wayland-scanner)\nBuildRequires:    pkgconfig(wayland-protocols) >= 1.39' "$spec"; \
    grep -q '^BuildRequires:.*pkgconfig(wayland-protocols)' "$spec"; \
    sed -i 's|^\([[:space:]]*\)--with-gtk4 \\$|&\n\1--with-wayland \\|' "$spec"; \
    grep -q -- '--with-wayland' "$spec"; \
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

# Only the patched sources contain these log strings, so a build that lost a
# patch fails here instead of shipping a stock binary. There is one per patch,
# in patch order, except 0005, which adds only configure and build rules. The
# Wayland strings after it cannot be built without that patch.
RUN set -eux; \
    cd "$(mktemp -d)"; \
    rpm2cpio /rpms/open-vm-tools-desktop-*.rpm | cpio -idm --quiet; \
    so=./usr/lib64/open-vm-tools/plugins/vmusr/libdndcp.so; \
    strings "$so" | grep -q 'unsafe fileItem'; \
    strings "$so" | grep -q 'no XDG_CURRENT_DESKTOP'; \
    strings "$so" | grep -q 'no X display, uinput disabled'; \
    strings "$so" | grep -q 'drag entering, telling the host'; \
    strings "$so" | grep -q 'using ext-data-control-v1'; \
    strings "$so" | grep -q 'host clip offers'; \
    strings "$so" | grep -q 'clipboard text too large'; \
    strings "$so" | grep -q 'wl-copy is not installed'; \
    strings "$so" | grep -q 'reading the selection only after it changes'; \
    strings "$so" | grep -q 'skipping non-file uri'; \
    strings "$so" | grep -q 'paste observed, requesting files'; \
    strings "$so" | grep -q 'managed after'; \
    strings "$so" | grep -q 'native drag source ready'; \
    strings "$so" | grep -q 'drag started from serial'; \
    strings "$so" | grep -q 'formats natively'; \
    strings "$so" | grep -q 'placeholders under'; \
    strings "$so" | grep -q 'never agreed'; \
    strings "$so" | grep -q 'Mutter bridges XDND'; \
    strings "$so" | grep -q 'outlived the drop'; \
    strings "$so" | grep -q 'native drop target shown on'; \
    strings "$so" | grep -q 'PruneStagingDirectories'; \
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
# the bootstrap order. The policy lives inside the image, so a machine has to
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
