# Rootless GNU Guix 1.5.0 with Bubblewrap

Install **GNU Guix 1.5.0** as a normal Linux user without putting `/gnu/store` or `/var/guix` on the host filesystem. Originally developed on the **Steam Frame KDE desktop**, but intended for other Linux systems that support rootless Bubblewrap and unprivileged user namespaces.

The installer detects the host architecture, downloads the appropriate official Guix archive, verifies its SHA-256 checksum, creates the isolated filesystem layout, starts a rootless daemon, authorizes official binary substitutes, and sets up XDG-compatible GUI launchers and desktop integration.

## Supported architectures

| Detected Linux architecture | Guix archive architecture |
|---|---|
| `x86_64`, `amd64` | `x86_64` |
| `i386`, `i486`, `i586`, `i686` | `i686` |
| `armv6l`, `armv7l`, `armv8l`, `armhf` | `armhf` (requires a compatible hard-float userspace) |
| `aarch64`, `arm64` | `aarch64` |
| `ppc64le`, `powerpc64le` | `powerpc64le` |
| `riscv64` | `riscv64` |

On an `x86_64` kernel with a 32-bit userspace, the installer selects `i686` when `getconf LONG_BIT` reports 32. All six Guix 1.5.0 archive URLs and their SHA-256 hashes are pinned to the GNU release. **Architecture support does not mean every package has a prebuilt substitute on every architecture.**

## Requirements

- Linux with working **unprivileged user namespaces** and an installed `bwrap` (Bubblewrap) executable. Sandboxed builds may require *nested* namespace support in addition to the initial Bubblewrap invocation.
- `bash`, GNU `tar` with `.xz` support, `sha256sum`, and ordinary core utilities; `curl` or `wget` to download the archive.
- Enough free space for the approximately 120–135 MB compressed archive, the extracted Guix store, and any packages (potentially gigabytes).
- Internet access to the GNU FTP server and Guix substitute servers, unless supplying an existing archive (package installation still needs internet).
- An XDG/freedesktop.org-compatible desktop session (such as KDE Plasma, GNOME, Xfce, Cinnamon, MATE, or LXQt) for application-menu integration. Guix itself also works without a desktop.
- A reachable **systemd user manager** is preferred for automatic daemon startup. If unavailable, the installer configures **XDG autostart** and starts the daemon directly for the current session.

No `sudo` is used. This is **not** a replacement for the upstream system-wide Guix installation on a normal multiuser machine.

## Install

Extract the ZIP and, as your regular user, run:

```bash
bash install.sh
```

It will choose the archive for your CPU, download and verify it, and install `hello` and `xterm` as example packages. XTerm may pull in significant graphical dependencies.

Options:

```bash
bash install.sh --help
bash install.sh --no-examples          # infrastructure only
bash install.sh --with-geany           # also install GTK editor Geany
bash install.sh --arch aarch64         # manually select the archive
bash install.sh --archive ~/Downloads/guix-binary-1.5.0.aarch64-linux.tar.xz
bash install.sh --reuse                # regenerate helpers using an existing installation
```

**Important:** `--arch` must match your *running userspace*, not just your CPU. An incompatible Guix executable will not run. `--reuse` skips downloading/extracting and expects an intact Guix installation; it does not merge or repair partial data. Without `--reuse`, an existing store or state directory causes a **safe refusal**, not an overwrite.

The current shell's `PATH` cannot be changed by a child installer script. Start a new terminal, or apply immediately:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

The desktop integration respects `XDG_DATA_HOME` and `XDG_CONFIG_HOME` for application launchers and autostart entries (defaulting to `~/.local/share` and `~/.config`). The synchronization helper only writes standard `.desktop` files; it does not run any desktop-specific menu refresh command. Compliant desktop environments normally discover additions and changes automatically.

The installer records its installation paths for later cleanup and appends a guarded PATH addition to `~/.profile` and the appropriate Bash/Zsh rc file, without replacing their other contents.

## Completely uninstall Guix

From the extracted installer directory, run:

```bash
bash install.sh --uninstall
```

**This is destructive:** it removes **the entire rootless Guix installation** at `~/.local/share/guix`, including **all installed packages, immutable store objects, profile generations, Guix daemon state/database, substitute signing-key authorization and copied desktop icons**. It also removes the Guix cache under `${XDG_CACHE_HOME:-~/.cache}/guix` (using the recorded install-time XDG path when available).

The uninstall command shows what it will remove and requires you to type `uninstall Guix` to confirm. For scripted/unattended use **only when you deliberately want to erase all Guix packages**:

```bash
bash install.sh --uninstall --yes
```

The uninstaller:

- Disables and stops its systemd user service, trying the normal user bus and then the Steam Frame's outer user bus. A running Guix daemon must be stopped before the store is deleted; it refuses to proceed if an enabled service cannot be disabled or the daemon is still responding.
- Stops manually or XDG-autostarted daemons only when their process environment identifies **this specific rootless Guix installation**, rather than terminating unrelated Guix processes.
- Removes the generated wrapper/helper scripts from `~/.local/bin`, generated `.desktop` application entries and XDG autostart entries, and the installer-created user service.
- Removes recognized `~/.guix-profile` and `~/.config/guix/current` symlinks pointing into the Guix profile tree, and removes the exact PATH additions marked by the installer in `~/.profile`, `~/.bashrc`, and `~/.zshrc`.
- Handles Guix store directories that are read-only by making the **directories** user-writable before deleting them. It does not require `sudo`.
- Preserves unrelated files in shared XDG directories, other shell customizations, user-created Guix channel/configuration files (such as `~/.config/guix/channels.scm`), and archive downloads in `~/Downloads`. The extracted installer ZIP/directory are also retained.

The installer records its resolved XDG directories in `~/.local/share/guix/.guix-bwrap-installer` for accurate removal even if you later run the uninstaller with a different environment. It can also recognize files generated by earlier versions of this ZIP that did not record paths; those older installations are assumed to have used default XDG locations when no matching environment is supplied. If you customized a generated helper or service, the uninstaller may deliberately preserve it instead of deleting unrelated-looking files. Review any such leftovers yourself.

**Important:** previous manual PATH edits made before using this installer, such as adding `~/.local/bin` to your shell's PATH, are deliberately left intact because removing them could break other programs.

If the uninstaller reports it cannot disable the daemon service, run it from a session with access to the systemd user bus, or first disable/stop `guix-daemon.service` using the Steam Frame user-bus instructions below. Do not delete the store while the daemon is running.

## What is installed

Persistent package store and daemon state:

```text
~/.local/share/guix/
├── gnu/store/                 # installed immutable store objects
├── var/guix/                  # daemon database, socket, profiles, logs
├── etc/guix/                  # substitute authorization ACL
└── desktop-icons/            # copied icons for GUI menu entries
```

Generated helpers:

| Command | Purpose |
|---|---|
| `guix-env.sh COMMAND ...` | Run a command inside the Guix Bubblewrap mount namespace |
| `guix-gui.sh COMMAND ...` | Run a GUI command with the active Wayland/X11/audio/GPU session mounted |
| `guix-pkg install PACKAGE` | Run the Guix package command and resync desktop entries |
| `guix-desktop-sync` | Create/update XDG desktop launchers from Guix profile `.desktop` files |
| `guix-daemon-launch` | Fallback start command when user systemd is unavailable |

Also created:

- `$XDG_CONFIG_HOME/systemd/user/guix-daemon.service` — systemd user service (defaults to `~/.config/systemd/user`); enabled if supported.
- `$XDG_CONFIG_HOME/autostart/guix-daemon.desktop` — created **only** as an XDG autostart fallback when systemd user services cannot be enabled.
- `$XDG_CONFIG_HOME/autostart/guix-desktop-sync.desktop` — sync desktop entries at each graphical desktop login.
- `$XDG_DATA_HOME/applications/guix-bwrap-*.desktop` — generated desktop launchers for packages that provide a `.desktop` file.
- `$XDG_DATA_HOME/applications/guix-xterm.desktop` — generated specifically when XTerm is installed (its Guix package may not include a `.desktop` file).

The Guix user profile is normally `~/.guix-profile`, a symlink to Guix-managed profiles presented by Bubblewrap at `/var/guix`.

## Desktop compatibility

The application launchers use the freedesktop.org Desktop Entry Specification, and the login hooks use the XDG Autostart Specification. No `OnlyShowIn=KDE;` restrictions are present. A desktop or menu implementation that follows those standards (for example, KDE Plasma, GNOME, Xfce, Cinnamon, MATE, or LXQt) can discover the entries. If the session does not implement those standards, you can still launch programs from a terminal with `guix-gui.sh` and start the daemon manually or via another init system.

There is no universal XDG command to force a menu refresh. `guix-desktop-sync` creates, updates, and removes standard `.desktop` entries in the XDG applications directory, leaving menu discovery and caching to the desktop environment. `update-desktop-database` only updates MIME associations, not application menus. If an entry does not appear immediately, the desktop may require its menu to be reopened or the session to be restarted. Each GUI application is launched using the active display session's environment, and individual toolkits may need extra portal or device configuration.

## Everyday usage

```bash
guix-env.sh guix --version
guix-pkg install geany
guix-pkg upgrade
guix-pkg remove geany
guix-desktop-sync
guix-gui.sh xterm
guix-gui.sh geany
```

Graphical applications started through `guix-gui.sh` inherit the **currently active desktop session**. Launch GUI apps from your intended graphical session, not an unrelated outer/VR session, so that the correct `XDG_RUNTIME_DIR`, display and D-Bus details are inherited.

XDG application entries are copied from `~/.guix-profile/share/applications` and their `Exec=` values are prefixed with `guix-gui.sh`. Simple standard desktop entries are supported, including basic icons and desktop actions; complex D-Bus-activated apps, portals, desktop-file quoting edge cases, or applications needing additional host devices may need manual changes. A message saying *“Synchronized 0 Guix-provided desktop launcher(s)”* is normal until you install a package providing a `.desktop` file. `xterm` gets a special launcher regardless.

`guix-pkg` synchronizes entries after `install`, `remove`, and `upgrade`. If you execute a package command directly with `guix-env.sh guix ...`, run `guix-desktop-sync` afterward.

## Steam Frame: user systemd bus

The Steam Frame desktop may use a different D-Bus session and runtime directory from its outer systemd user manager. The installer tries `systemctl --user` normally and then tries the outer bus at `/run/user/$(id -u)/bus` if necessary, **without globally overriding** the KDE session's runtime variables.

To inspect the service manually from the Steam Frame desktop:

```bash
RUNTIME="/run/user/$(id -u)"
XDG_RUNTIME_DIR="$RUNTIME" \
DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
systemctl --user status guix-daemon.service --no-pager
```

If neither bus is accessible, the installer creates an XDG autostart entry. On compliant desktops, the daemon then starts at graphical login instead of through systemd. On a headless system or a session that does not implement XDG autostart, start the daemon yourself, for example:

```bash
~/.local/bin/guix-env.sh guix-daemon
```

Keep that terminal open while installing packages. Do **not** run two copies of `guix-daemon` against the same store/state directory.

## Troubleshooting

**`bwrap: ... Operation not permitted`** — The host may block unprivileged user namespaces. The installer cannot fix kernel or system policy restrictions without administrator control. Do not use `--disable-chroot` as a blanket workaround; it weakens build isolation.

**`Failed to connect to user scope bus`** — On the Steam Frame, use the outer-user-bus command above. If user systemd is not available, use XDG autostart or a manually launched daemon.

**Guix cannot connect to its daemon** — Check:

```bash
guix-env.sh guix gc --list-roots
journalctl --user -u guix-daemon.service -n 50 --no-pager
cat ~/.local/share/guix/var/guix/daemon.log   # XDG autostart fallback only
```

**DNS failures** — This setup mounts host `/etc` and `/run` read-only inside Bubblewrap because `/etc/resolv.conf` may refer to a file under `/run`. Verify name resolution on the host, then compare with `guix-env.sh getent hosts ci.guix.gnu.org` if `getent` is installed.

**“ACL for archive imports seems to be uninitialized”** — Signing keys were not authorized. If the daemon is running, retry:

```bash
guix-env.sh /bin/bash -c '
  set -e
  d=/var/guix/profiles/per-user/root/current-guix/share/guix
  for s in ci.guix.gnu.org bordeaux.guix.gnu.org; do
    guix archive --authorize < "$d/$s.pub"
  done
'
```

**Everything will be built from source** — Check DNS, the ACL, and actual substitute availability for your architecture. The installer trusts only the official Guix signing keys bundled with the downloaded archive.

**GUI app does not open** — Try `guix-gui.sh app-name` from a terminal in your graphical desktop session. Some graphics/audio/DBus applications require app-specific adjustments. Being able to run XTerm does not guarantee every GUI application will work.

## Security and design notes

- The archive is **SHA-256 checked** against hashes copied from the official Guix 1.5.0 release announcement. This does **not** perform a separate GPG signature verification; for stricter supply-chain assurance, independently verify the corresponding `.sig` file using the Guix release-signing key and a trusted key fingerprint before installing.
- The normal wrapper makes `/gnu/store` and `/var/guix` visible only within Bubblewrap. It shares the network and **your home directory**. The GUI wrapper additionally shares `/tmp`, runtime sockets (Wayland, X11, PulseAudio/PipeWire, D-Bus) and GPU devices. **It is not a security sandbox for untrusted applications.**
- Rootless Guix builds require usable unprivileged namespaces. The installer deliberately does not force `--disable-chroot`.
- `~/.local/share/guix` holds persistent Guix store/state; helper scripts, your user profile, shell configuration, XDG desktop launchers and the user service must live in their conventional home-directory locations.
- This installer is intended for a **fresh** per-user installation. Re-running it with `--reuse` regenerates its helper scripts, XDG autostart entries and user service file; back up local customizations before doing so. Do not delete a live Guix store.

## Primary references

- [GNU Guix 1.5.0 release announcement and archive hashes](https://lists.gnu.org/archive/html/info-gnu/2026-01/msg00004.html)
- [Official Guix archive directory](https://ftp.gnu.org/gnu/guix/)
- [Guix manual](https://guix.gnu.org/manual/en/)
- [Rootless Guix daemon design](https://hpc.guix.info/blog/2025/03/build-daemon-drops-its-privileges/)
- [Desktop Entry Specification](https://specifications.freedesktop.org/desktop-entry/latest/)
- [Desktop Application Autostart Specification](https://specifications.freedesktop.org/autostart-spec/latest/)

This is a community-style convenience installer, **not an official GNU Guix installer**. It has been checked for shell syntax but has not been end-to-end tested on all six architectures or all Linux desktop environments.
