# bazzite-ovt

Bazzite with `open-vm-tools` rebuilt so that clipboard and drag and drop work
under a Wayland session, in both directions and for every format the protocol
defines.

Stock `open-vm-tools` ships only an X11 copy-paste backend. Under Wayland the
daemon can only reach Xwayland's clipboard, and compositors refuse clipboard
reads from an unfocused Xwayland client, so guest -> host copy fails. This
image adds a Wayland backend that owns the local selection directly through
`ext-data-control-v1`, which is designed for windowless clipboard clients and
has no focus requirement.

Tracks open-vm-tools [#792](https://github.com/vmware/open-vm-tools/issues/792)
and [#510](https://github.com/vmware/open-vm-tools/issues/510).

## Status

| | guest -> host | host -> guest |
|---|---|---|
| Plain text | works | works |
| PNG images | works | works |
| Rich text (RTF) | works | works |
| Files | works | works |
| Drag and drop | works | works |

Verified on Bazzite 44 (Fedora 44, KDE Plasma 6.7.5, Wayland), open-vm-tools
13.1.0, against VMware Workstation Pro 26H1u1 (26.0.1.25688693) on a Windows
10 Pro 22H2 host, build 19045.7725. Capabilities negotiate to
`0x1555` for copy/paste and `0xaab` for drag and drop, which is
`DND_CP_CAP_FORMATS_ALL`: the same set the X11 backend reports.

A single rich text copy pastes with its formatting into a word processor and
as clean plain text into a plain text editor. Files go both ways as single
items and as multi-file selections, by drag and drop as well as copy and
paste.

## Owning the selection

The obvious way to reach the Wayland clipboard from a daemon is to shell out
to `wl-clipboard`, and it is not sufficient. `wl-copy` takes a single
`--type` and serves one payload, so one selection cannot carry rich text and
a plain rendering at the same time. The host sends both for a rich text copy,
and the X11 backend passes both on as separate selection targets. With
`wl-copy` you must choose between dropping the formatting and handing plain
text targets the raw RTF markup.

So the backend binds `ext_data_control_manager_v1` and owns the selection
itself, answering each request with the bytes for the type that was asked
for. That is what the X11 backend has always done, and it is why the
capability set can match it.

`ext-data-control-v1` is the standardised protocol in wayland-protocols,
supported by KWin and wlroots compositors. Where it is absent the backend
falls back to `wl-clipboard`, which keeps the single payload limit and so
cannot carry RTF. GNOME is the case that matters here: it declines to
implement data control protocols.

Reads and writes on the selection are bounded by a deadline rather than left
to block. The daemon's main loop also carries the RPC channel to the host, so
a peer that stops reading must not be able to wedge it.

## Host -> guest files are lazy

Nothing is transferred when you copy. On receiving a file list the guest
creates a staging directory, places a `vmblock` on it, and publishes a
`text/uri-list` of paths under `/run/vmblock-fuse/blockdir/`, a few hundred
bytes. A monitor thread blocks reading the matching path under
`/run/vmblock-fuse/notifydir/`, which returns only when the pasting
application opens one of those files. That is when the bytes are requested.
Copying a 4 GB file on the host and never pasting it transfers nothing.

This requires `run-vmblock\x2dfuse.mount` to be active and `vmtoolsd -n vmusr`
to be started with `--blockFd` by `vmware-user-suid-wrapper`. Both are the
default on Fedora. Where vmblock is unavailable the paste is declined and
logged, rather than falling back to copying everything eagerly.

A clipboard carrying file *contents* instead of paths is handled separately.
The host sends the bytes when its source has no file on disk to point at, so
there is nothing to stall a reader for: the contents are written into the
staging area and the resulting paths published like any other list.

Pasted files keep the permissions the host reports. A file marked read-only on
Windows arrives as `r-xr--r--`, which is upstream behaviour, not a bug in these
patches.

## Guest -> host files

No vmblock is involved in this direction: the guest publishes the list and the
host pulls the contents itself. Non-file URI schemes (`trash:`, `recent:`) are
skipped rather than resolved.

Names in a host-supplied file list are treated as untrusted. CR and LF are
percent-escaped, since either would otherwise end an entry and inject a
further URI into the list, and an entry containing a `..` component is
rejected rather than being allowed to escape the staging directory the block
covers.

## Drag and drop

Drag and drop is delegated to the existing X11 implementation, so under a
Wayland session the detection window is an Xwayland client and the compositor
bridges its XDND to native clients. Several separate faults stopped that
working, each of which alone lost every guest -> host drag, so fixing any one
of them on its own looked like no improvement at all.

**The detection window must stay managed.** It set override-redirect. A
compositor bridging a native Wayland drag to an Xwayland window looks its
target up among managed clients, so an unmanaged window is never offered the
drag and no `XdndEnter` arrives. On KWin that lookup is
`Workspace::findClient()` by way of `XwlDropHandler::updateDragTarget()`.
Focus is suppressed with window manager hints instead.

**The pointer warp must wait for the window manager.** A window does not
become a drag target the moment it maps: the compositor has to adopt it and it
has to paint, both of which happen roughly 100 ms after `MapNotify`. Nothing
re-evaluates the choice afterwards, because the target is picked on pointer
motion and the only motion in the sequence is the warp that follows
immediately. The previous code slept 300 *microseconds* here.

That wait does not iterate the main loop. It runs from an RPC handler, and
`GuestDnDMgr::OnRpcQueryExiting()` shows the detection window before recording
the session id, so a command dispatched from inside the wait would run that
sequence again and the outer call would write the older session id last. Every
later command for the real session is rejected after that, leaving drag and
drop broken until something resets it.

The detection window is shown twice in a host -> guest drop, once to be
positioned and once to source the drag, and only the first may move the
pointer. The two are told apart by an explicit role.

**The file list must be read as `text/uri-list`.** GTK's drop target preload
picks `application/vnd.portal.filetransfer` when the source is a KDE
application, and the XDG document portal authenticates a caller by opening
`/proc/<pid>/root`. It cannot do that for a process exec'd by a setuid
wrapper, because that clears the kernel's dumpable flag and leaves
`/proc/<pid>` owned by root even after privileges are dropped.

Note that `dragDetWndX11GTK4.cpp` is shared with the X11 backend, so the
managed detection window, the adoption wait and the explicit uri-list read
apply to plain X11 GTK4 sessions as well. That combination is untested.

## Patches

Four patches against `open-vm-tools 13.1.0-25218885`, applied in order by the
Containerfile. Each patch carries its reasoning in its commit message.

| Patch | What it does |
|---|---|
| `0001-dndcp-wayland-clipboard` | Wayland clipboard backend: text, PNG, RTF, file lists, file contents. Adds `waylandClipboard/`, which binds `ext-data-control-v1` and owns the selection. |
| `0002-dndcp-wayland-drag-and-drop` | Drag and drop both directions, delegated to the X11 backend over Xwayland. Raises `GetCaps()` to `DND_CP_CAP_FORMATS_ALL`. |
| `0003-dndcp-detwnd-geometry` | Stops the code assuming the compositor places the detection window where it asked. |
| `0004-dndcp-robustness` | A NULL `XOpenDisplay()` no longer kills the daemon, and a faked button press is always released. |

The clipboard backend is derived from
[clipway](https://github.com/krisztianfekete/clipway) by Krisztián Fekete,
which provided the original text-only version. LGPL-2.1, inherited from
open-vm-tools.

### Using them outside this image

Nothing in the patches is specific to Bazzite, or to an image-based distro at
all. Only the packaging here is: the Containerfile, the bootc switch and the
cosign setup. The patches go into any `open-vm-tools` build.

What they do need:

- **open-vm-tools 13.1.0.** They apply to `13.1.0-25218885`. Earlier releases
  moved these files around, and the build pins the version deliberately so a
  bump breaks loudly rather than producing a silently unpatched image.
- **A GTK4 build, for drag and drop only.** `dndUIX11GTK4.cpp` and
  `dragDetWndX11GTK4.cpp` live inside the `HAVE_GTK4` conditional in
  `Makefile.am`, so patches 0002 to 0004 need `--enable-gtk4`. Patch 0001
  touches only files built in every configuration, so the clipboard works on a
  GTK3 build too.
- **libwayland-client**, which patch 0001 adds to `LIBADD`. The generated
  `ext-data-control-v1` protocol sources are included, so `wayland-scanner` is
  not needed at build time.
- **A compositor implementing `ext-data-control-v1`** for the full clipboard.
  Without it the backend falls back to `wl-clipboard`, which cannot carry RTF.

### Portability

The patches target the protocols rather than any one compositor:
`ext-data-control-v1` for the selection, XDND and EWMH for drag and drop.
Verified on KDE Plasma 6.7.5 and on sway 1.11, both Wayland, in a VMware
guest. `dragDetWndX11GTK4.cpp` is shared with the X11 backend, so plain X11
GTK4 sessions get the same behaviour; that combination is untested.

Two things vary by compositor.

A compositor is only obliged to honour the size a window is mapped with, and a
tiling one owns window geometry outright. The detection window is a small
helper that must not be stretched over the output, where it covers the drop
target and takes the drop meant for it. Patch 0003 maps it at its real size
and asks for a fixed size, which is the ICCCM way to say a window cannot
usefully be resized. A compositor that tiles it regardless has to be told to
float it in its own configuration, for example:

```
for_window [title="vmware-user"] floating enable
```

Host to guest drops reach X11 and Xwayland applications, but not native
Wayland ones under wlroots, which does not yet carry a drag from an X11 source
to a Wayland client
([wlroots#841](https://github.com/swaywm/wlroots/pull/841)). That limit is
the compositor's, not this plugin's. On sway 1.11 a plain GTK3 drag source
on the X11 backend reaches an X11 target and is ignored by a Wayland one,
and open-vm-tools is not involved in that test at all. KWin carries the
same drag, so drops into Dolphin arrive.

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
way, as a `%prep` failure.

The build also greps the finished library for one literal per patch, so a patch that
silently stops applying fails the build rather than shipping a stock binary.

Customise this image by editing the Containerfile, not with local
`rpm-ostree install/remove` on the running system. Local modifications make
`bootc upgrade` refuse to run until `rpm-ostree reset`.

`vmtoolsd -n vmusr` needs no unit file. Fedora's
`/etc/xdg/autostart/vmware-user.desktop` runs `vmware-user-suid-wrapper`, which
since 13.x detects `XDG_SESSION_TYPE=wayland`, opens `/dev/uinput` for
`fakeMouseWayland`, and execs the daemon with the session environment intact.
Do not replace it with a user unit calling `/usr/bin/vmtoolsd` directly: that
drops the uinput and block descriptors, breaking pointer handling, file paste
and drag and drop.

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
grep -a 'ping reply caps' /tmp/vmusr.log     # want 1555 and aab
grep -a 'ext-data-control' /tmp/vmusr.log    # want: using ext-data-control-v1
grep -a 'vmblock' /tmp/vmusr.log             # want: vmblock ready (fd 3)
grep -a -iE 'host clip offers|formats locally|bytes of|paste observed' /tmp/vmusr.log
```

A working file paste logs `added block`, then the URI list on copy, then
`paste observed, requesting files` only when you actually paste, then
`removing block`. If the transfer starts at copy time rather than paste time,
something is wrong.

A working guest -> host drag logs, in order: `QUERY_EXITING` from the host,
`managed after Nms` from the adoption wait, `XDND accept reached the detection
window`, `reading drop as text/uri-list`, and `drag entering, telling the
host`. The whole handshake takes about 110 ms.

`vmtoolsd --debug` takes a *plugin path* argument and is not a verbosity flag.
Note also that guest -> host only logs when the host requests the selection,
that is when you click into the host to paste, not at copy time.

### Testing a local build without rebuilding the image

A full image build takes about half an hour. To try a change against a running
system, bind-mount a locally built plugin over the installed one and restart
the daemon. Three things bite if you improvise this:

```bash
# 1. Stop vmusr FIRST. While it runs the library is mapped, so the unmount
#    fails "target is busy" and the old build keeps being served. libtool
#    writes a new inode every build, so findmnt shows "//deleted".
pkill -f 'vmtoolsd -n vmusr'
sudo umount /usr/lib64/open-vm-tools/plugins/vmusr/libdndcp.so
sudo mount --bind <build>/.libs/libdndcp.so \
                  /usr/lib64/open-vm-tools/plugins/vmusr/libdndcp.so

# 2. XAUTHORITY is required and is renamed at every login, so discover it
#    rather than trusting an inherited value. Without it vmusr exits on
#    "Failed to open display" and everything looks broken.
# 3. Without XDG_SESSION_TYPE=wayland the suid wrapper omits --uinputFd and
#    the pointer warp silently does nothing.
setsid nohup env \
  DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u) \
  XAUTHORITY="$(ls -t /run/user/$(id -u)/xauth_* | head -1)" \
  XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus \
  /usr/bin/vmware-user-suid-wrapper </dev/null >/dev/null 2>&1 &
```

Confirm it came back correctly: `pgrep -af 'vmtoolsd -n vmusr'` should show
both `--blockFd` and `--uinputFd`. The bind mount survives a logout but not a
reboot.
