# bazzite-ovt

Bazzite with `open-vm-tools` rebuilt so that clipboard copy/paste works under a
Wayland session: text, PNG images, and host -> guest file paste.

Stock `open-vm-tools` ships only an X11/GtkClipboard copy-paste backend. Under
Wayland the daemon can only reach Xwayland's clipboard, and compositors refuse
clipboard reads from an unfocused Xwayland client, so guest -> host copy fails.
This image adds a Wayland backend that drives the local selection through
`wl-copy`/`wl-paste` (`wlr-data-control` / `ext-data-control-v1`), which is
designed for windowless clipboard clients and has no focus requirement.

Tracks open-vm-tools [#792](https://github.com/vmware/open-vm-tools/issues/792)
and [#510](https://github.com/vmware/open-vm-tools/issues/510).

## Status

| | guest -> host | host -> guest |
|---|---|---|
| Plain text | works | works |
| PNG images | works | works |
| Files | works | works |
| Drag and drop | no | no |

Verified on Bazzite 44 (Fedora 44, KDE Plasma 6, Wayland), open-vm-tools
13.1.0, VMware Workstation 26H2 on a Windows host. Copy/paste negotiates
version 4 with capabilities `0x515`
(`VALID | CP | PLAIN_TEXT_CP | IMAGE_CP | FILE_CP`). Images confirmed at ~2 MB
guest -> host and ~91 KB host -> guest; file transfer confirmed in both
directions for single files, a 16.4 MiB archive, and multi-file selections.

Cross-checked against a stock X11 guest (Ubuntu, open-vm-tools 13.0.10, caps
`0x1555`) on the same host, which is bidirectional for text and images. The
host offers these formats to Linux guests without trouble; a guest only
receives a format it advertised in `GetCaps()` first, which is why each feature
here comes with a capability bit as well as a handler.

### Host -> guest files are lazy

Nothing is transferred when you copy. On receiving a file list the guest
creates a staging directory, places a `vmblock` on it, and publishes a
`text/uri-list` of paths under `/run/vmblock-fuse/blockdir/` — a few hundred
bytes. A monitor thread blocks reading the matching path under
`/run/vmblock-fuse/notifydir/`, which returns only when the pasting
application opens one of those files. That is when the bytes are requested.
Copying a 4 GB file on the host and never pasting it transfers nothing.

This requires `run-vmblock\x2dfuse.mount` to be active and `vmtoolsd -n vmusr`
to be started with `--blockFd` by `vmware-user-suid-wrapper`. Both are the
default on Fedora. Where vmblock is unavailable the paste is declined and
logged, rather than falling back to copying everything eagerly.

Pasted files keep the permissions the host reports. A file marked read-only on
Windows arrives as `r-xr--r--`, which is upstream behaviour, not a bug in these
patches.

### Guest -> host files

No vmblock is involved in this direction: the guest publishes the list and the
host pulls the contents itself. Non-file URI schemes (`trash:`, `recent:`) are
skipped rather than resolved, since this backend links no Gtk stack and file
managers put `file://` URIs on the clipboard.

### Drag and drop

Not implemented, and not a small addition. Wayland has no `data-control`
equivalent for DnD: `wl_data_device.start_drag` needs a surface plus a serial
from a real input event, and drop targets need a surface under the pointer.
`vmtoolsd -n vmusr` has no surface — on X11 it fakes one with
`dragDetWndX11.cpp`, which cannot be done on Wayland.

## Patches

`patches/0001-dndcp-wayland-clipboard-backend.patch` — from
[clipway](https://github.com/krisztianfekete/clipway) by Krisztián Fekete,
unmodified. Adds the Wayland backend, selected at runtime when
`WAYLAND_DISPLAY` is set and either `DISPLAY` is unset or
`XDG_SESSION_TYPE=wayland`, so one build serves both session types. Text only.
LGPL-2.1, inherited from open-vm-tools. Upstream pins it to 13.0.5; it applies
to 13.1.0 with a line offset and no rebase, because the only pre-existing files
it touches are `dndcp/Makefile.am` (its hunk anchors below the `HAVE_GTK4`
conditional) and `dndGuestBase/copyPasteDnDWrapper.cpp` (byte-identical between
the two releases).

`patches/0002-dndcp-wayland-png-clipboard-support.patch` — adds
`CPFORMAT_IMG_PNG` in both directions, mirroring `copyPasteUIX11.cpp`. It also
advertises `DND_CP_CAP_IMAGE_CP` in `CopyPasteDnDWayland::GetCaps()`; without
that the VMX resolved capabilities to `0x15` and the image code was unreachable
no matter how correct it was. It prefers PNG over text in
`GetRemoteClipboardCB`, because the host can attach a text rendering to an
image copy and consuming text first silently discarded the bitmap. Reading
needs a binary-safe path: the existing text helper recovers its length with
`strlen`, which cannot carry the NUL bytes every PNG contains.

`patches/0003-dndcp-wayland-file-copy-paste.patch` — adds
`CPFORMAT_FILELIST` in both directions, plus `DND_CP_CAP_FILE_CP`. Host ->
guest uses the lazy vmblock delivery described above; `CopyPasteDnDWayland`
gains the block plumbing it had no equivalent of, fed from `ctx->blockFD`.
Guest -> host parses the local `text/uri-list` into a `DnDFileList`. Both
directions probe for files ahead of image and text.

The X11 backend's `FORMATS_ALL` is deliberately *not* copied in any of these —
claiming RTF or DnD bits would promise formats with no implementation behind
them.

## Build and deploy

CI builds, pushes and signs on every push to `main` and weekly. To build
locally:

```bash
podman build -t ghcr.io/<you>/bazzite-ovt:latest .
podman push ghcr.io/<you>/bazzite-ovt:latest
```

First switch, or after changing the image reference:

```bash
sudo bootc switch ghcr.io/<you>/bazzite-ovt:latest
systemctl reboot
```

Subsequent updates, where the reference is unchanged and only the digest moves:

```bash
sudo bootc upgrade
systemctl reboot
```

Rollback is `sudo rpm-ostree rollback`, or `sudo bootc switch` back to
`ghcr.io/ublue-os/bazzite:stable`.

If you were previously using a local `rpm-ostree override replace`, drop it
first so the image's copy is what is deployed:

```bash
sudo rpm-ostree override reset open-vm-tools open-vm-tools-desktop
```

## Signing

Images are signed with cosign in CI. Verification is configured by the image
itself: `cosign.pub` is installed to `/etc/pki/containers/`, a `sigstoreSigned`
entry is added to `/etc/containers/policy.json`, and
`/etc/containers/registries.d/bazzite-ovt.yaml` sets `use-sigstore-attachments`
so the policy can find the signature.

That creates a bootstrap order: the policy ships *inside* the image, so a
machine must run the unsigned reference once before it can switch to the signed
one.

```bash
sudo bootc upgrade && systemctl reboot
sudo bootc switch ostree-image-signed:docker://ghcr.io/<you>/bazzite-ovt:latest
systemctl reboot
```

To set this up in a fork: generate a keypair with
`COSIGN_PASSWORD="" cosign generate-key-pair`, add `cosign.key` as the
`SIGNING_SECRET` repository secret, commit `cosign.pub` at the repo root, and
change `SIGNED_REPO` in the Containerfile. Never commit `cosign.key`.

## Maintenance

Adding a patch means dropping a file in `patches/`. The Containerfile rewrites
the spec from whatever that directory contains, in sorted order, registering
them as `Patch101` onward so they apply after Fedora's own. Nothing else needs
editing.

The build pins `OVT_VERSION` and fails if Fedora ships something else. That is
deliberate: a version bump should break the build, not silently produce an
unpatched image. When it fires, re-verify the patches against the new tree and
bump the arg. A new *Fedora* patch can also collide, which shows up the same
way — as a `%prep` failure.

Customise this image by editing the Containerfile, not with local
`rpm-ostree install/remove` on the running system. Local modifications make
`bootc upgrade` refuse to run until `rpm-ostree reset`.

`vmtoolsd -n vmusr` needs no unit file. Fedora's
`/etc/xdg/autostart/vmware-user.desktop` runs `vmware-user-suid-wrapper`, which
since 13.x detects `XDG_SESSION_TYPE=wayland`, opens `/dev/uinput` for
`fakeMouseWayland`, and execs the daemon with the session environment intact.
Do not replace it with a user unit calling `/usr/bin/vmtoolsd` directly — that
drops the uinput and block descriptors, breaking pointer handling and file
paste.

## Debugging

Logging is off by default. To turn it on, `/etc/vmware-tools/tools.conf`:

```ini
[logging]
log = true
vmusr.level = debug
vmusr.handler = file
vmusr.data = /tmp/vmusr.log
```

Log out and back in, then (`-a` because upstream's RpcIn lines contain NULs):

```bash
grep -a 'ping reply caps' /tmp/vmusr.log     # want 515
grep -a 'vmblock' /tmp/vmusr.log             # want: vmblock ready (fd 3)
grep -a -iE 'host clip offers|bytes of PNG|URI list|paste observed|sending .* file' /tmp/vmusr.log
```

A working file paste logs `added block`, then `publishing N bytes of URI list`
on copy, then `paste observed, requesting files` only when you actually paste,
then `removing block`. If the transfer starts at copy time rather than paste
time, something is wrong. A guest -> host file copy logs
`sending N file(s), M bytes total`.

`vmtoolsd --debug` takes a *plugin path* argument and is not a verbosity flag.
Note also that guest -> host only logs when the host requests the selection,
i.e. when you click into the host to paste — not at copy time.
