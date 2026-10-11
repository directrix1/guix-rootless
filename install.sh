#!/usr/bin/env bash
# GNU Guix 1.5.0, installed without root inside a Bubblewrap mount namespace.
# Linux only. Intended for single-user systems such as the Steam Frame desktop.
set -Eeuo pipefail

BASE_URL=https://ftp.gnu.org/gnu/guix
PREFIX="${HOME}/.local/share/guix"
BIN_DIR="${HOME}/.local/bin"
ARCH_OVERRIDE=''
LOCAL_ARCHIVE=''
REUSE=0
NO_EXAMPLES=0
WITH_GEANY=0
UNINSTALL=0
ASSUME_YES=0

info() { printf '\n[guix-bwrap] %s\n' "$*"; }
warn() { printf '\n[guix-bwrap] WARNING: %s\n' "$*" >&2; }
die()  { printf '\n[guix-bwrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Copy a template from src/ to its installed location, replacing each
# @NAME@ placeholder with the current value of the shell variable NAME.
# The src/ files stay static and browsable; only the install target varies.
render_template() {
  local src=$1 dest=$2
  local line name value
  while IFS= read -r line || [[ -n $line ]]; do
    while [[ $line =~ @([A-Z_]+)@ ]]; do
      name=${BASH_REMATCH[1]}
      [[ -n ${!name+set} ]] || die "Template $src uses undefined variable $name"
      value=${!name}
      line=${line/"${BASH_REMATCH[0]}"/"$value"}
    done
    printf '%s\n' "$line"
  done < "$src" > "$dest"
}

usage() {
  cat <<'USAGE'
Usage: bash install.sh [OPTIONS]

Install GNU Guix 1.5.0 rootlessly under ~/.local/share/guix.

Options:
  --arch ARCH       Override architecture detection (x86_64, i686, armhf,
                    aarch64, powerpc64le, riscv64).
  --archive FILE    Use a previously downloaded Guix .tar.xz archive.
  --reuse           Reuse an existing installation; do not re-extract.
  --no-examples     Do not install the 'hello' and 'xterm' example packages.
  --with-geany      Also install Geany (large GTK dependency download).
  --uninstall       Stop the daemon and remove this Guix installation, packages,
                    wrappers, launchers and integration files.
  --yes             Confirm destructive --uninstall without an interactive prompt.
  -h, --help        Show this help.

Requirements: Linux, bash, bubblewrap (bwrap), tar/xz, sha256sum,
              curl or wget, enough free disk space, and usable user namespaces.
No sudo, root access, or changes to /gnu or /var on the host.

The 'src/' directory must stay next to this script: the installer copies
its helper scripts, service unit and desktop entries from there.
USAGE
}

while (($#)); do
  case "$1" in
    --arch) (($# >= 2)) || die '--arch requires an argument'; ARCH_OVERRIDE="$2"; shift 2 ;;
    --archive) (($# >= 2)) || die '--archive requires a file'; LOCAL_ARCHIVE="$2"; shift 2 ;;
    --reuse) REUSE=1; shift ;;
    --no-examples) NO_EXAMPLES=1; shift ;;
    --with-geany) WITH_GEANY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ $(uname -s) == Linux ]] || die 'GNU Guix binaries and Bubblewrap require Linux.'
[[ $(id -u) != 0 ]] || die 'Run as your normal user, not root or sudo.'
[[ -n ${HOME:-} && -d "$HOME" ]] || die 'HOME is not set to an existing directory.'

# An uninstall must work even if bwrap, Guix, networking, or the archive
# are no longer available. Do not enter the installer prerequisite checks.
uninstall_guix() {
  (( ! REUSE && ! NO_EXAMPLES && ! WITH_GEANY )) || die '--uninstall cannot be combined with installation options.'
  [[ -z "$ARCH_OVERRIDE" && -z "$LOCAL_ARCHIVE" ]] || die '--uninstall cannot be combined with --arch or --archive.'
  for cmd in rm find chmod grep awk mktemp mv readlink head sleep; do
    command -v "$cmd" >/dev/null || die "Missing command for uninstall: $cmd"
  done

  local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
  local meta="$PREFIX/.guix-bwrap-installer"
  local key val
  # Read a plain-data installation record, NEVER source/evaluate it.
  if [[ -f "$meta" && ! -L "$meta" ]] &&
     [[ $(head -n 1 "$meta") == guix-rootless-bwrap-v1 ]]; then
    while IFS='=' read -r key val; do
      case "$key" in
        XDG_DATA_HOME) if [[ "$val" == /* && "$val" != / ]]; then data_home="$val"; fi ;;
        XDG_CONFIG_HOME) if [[ "$val" == /* && "$val" != / ]]; then config_home="$val"; fi ;;
        XDG_CACHE_HOME) if [[ "$val" == /* && "$val" != / ]]; then cache_home="$val"; fi ;;
      esac
    done < "$meta"
  fi
  # The expected prefix is fixed, but do not traverse one that was replaced
  # with a symlink. Also refuse an unknown directory named "guix".
  [[ ! -L "$PREFIX" ]] || die "Refusing to remove a symlinked Guix prefix: $PREFIX"
  if [[ -d "$PREFIX" && ! -d "$PREFIX/gnu/store" && ! -d "$PREFIX/var/guix" && ! -f "$meta" ]]; then
    die "Unrecognized directory at $PREFIX; refusing to delete it."
  fi
  local unit="$config_home/systemd/user/guix-daemon.service"
  if [[ -e "$unit" || -L "$unit" ]]; then
    [[ -f "$unit" && ! -L "$unit" ]] || die "Unexpected systemd unit at $unit; inspect it manually."
    if ! grep -Eq 'guix-env(\.sh)? guix-daemon' "$unit"; then
      die "Systemd unit $unit does not belong to this installer. Refusing to alter it."
    fi
  fi

  printf '\n[guix-bwrap] FULL UNINSTALL - the following will be removed:\n'
  printf '  Guix store, installed packages, profiles, daemon database and keys: %s\n' "$PREFIX"
  printf '  Guix package cache: %s/guix\n' "$cache_home"
  printf '  Generated helpers in: %s\n' "$BIN_DIR"
  printf '  Generated launchers in: %s/applications\n' "$data_home"
  printf '  Guix autostart and systemd user service in: %s\n' "$config_home"
  printf '  Recognized Guix profile symlinks: ~/.guix-profile, ~/.config/guix/current\n'
  printf '  Marked installer PATH lines in shell profile files\n'
  printf '  Preserved: downloaded archives, unrelated files, and custom Guix channel/configuration files\n'
  if (( ! ASSUME_YES )); then
    [[ -t 0 ]] || die 'Interactive confirmation unavailable; pass --uninstall --yes to proceed.'
    local answer
    read -r -p "Type 'uninstall Guix' to delete ALL installed Guix packages: " answer || die 'Uninstall cancelled.'
    [[ "$answer" == 'uninstall Guix' ]] || die 'Uninstall cancelled.'
  fi

  # Stop systemd service before deleting store. Handle an outer/Steam Frame
  # user bus without mutating the graphical session's global environment.
  local stopped=0 rt="/run/user/$(id -u)"
  if [[ -f "$unit" ]] && command -v systemctl >/dev/null; then
    if systemctl --user disable --now guix-daemon.service >/dev/null 2>&1; then
      stopped=1
    elif [[ -S "$rt/bus" ]] &&
      env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
        systemctl --user disable --now guix-daemon.service >/dev/null 2>&1; then
      stopped=1
    fi
  fi
  # If systemd had enabled the unit but we could not reach it, do not
  # delete files beneath a potentially still-running, restarting daemon.
  local wants="$config_home/systemd/user/default.target.wants/guix-daemon.service"
  if (( ! stopped )) && [[ -L "$wants" ]]; then
    die 'Could not disable the enabled systemd user service. Stop it from the correct user bus and retry; no files were deleted.'
  fi

  # Stop manual/XDG-autostart daemons only when their environment identifies
  # this exact Guix installation. Never blanket-pkill every guix-daemon.
  local proc pid comm
  for proc in /proc/[0-9]*; do
    [[ -r "$proc/comm" && -r "$proc/environ" ]] || continue
    IFS= read -r comm < "$proc/comm" || true
    [[ "$comm" == guix-daemon ]] || continue
    if grep -azFxq "GUIX_CONFIGURATION_DIRECTORY=$PREFIX/etc/guix" "$proc/environ" 2>/dev/null; then
      pid=${proc##*/}
      info "Stopping this installation's daemon (PID $pid)"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  sleep 1
  # A separate manually started daemon may lack our identifying environment.
  # If the local Guix socket still answers, bail out rather than corrupt its DB.
  local env_cmd=''
  if [[ -x "$BIN_DIR/guix-env" ]]; then
    env_cmd="$BIN_DIR/guix-env"
  elif [[ -x "$BIN_DIR/guix-env.sh" ]]; then # pre-rename installs
    env_cmd="$BIN_DIR/guix-env.sh"
  fi
  if [[ -n "$env_cmd" ]] && command -v timeout >/dev/null &&
     command -v bwrap >/dev/null && [[ -d "$PREFIX/gnu/store" ]]; then
    if timeout 6 "$env_cmd" guix gc --list-roots >/dev/null 2>&1; then
      die 'The Guix daemon is still responding! Stop it first and rerun uninstall; no files were deleted.'
    fi
  fi

  # Remove only entries unmistakably generated for this rootless Guix setup.
  local f
  for f in "$data_home"/applications/guix-bwrap-*.desktop; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    if grep -Fxq 'X-Guix-Bwrap-Generated=true' "$f"; then rm -f -- "$f"; fi
  done
  f="$data_home/applications/guix-xterm.desktop"
  if [[ -f "$f" && ! -L "$f" ]] &&
     { grep -Fxq 'X-Guix-Bwrap-Generated=true' "$f" ||
       grep -Eq 'guix-gui(\.sh)?"? xterm' "$f"; }; then
    rm -f -- "$f"
  fi
  for f in "$config_home/autostart/guix-desktop-sync.desktop" \
           "$config_home/autostart/guix-daemon.desktop"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    if grep -Eq 'guix-desktop-sync|guix-daemon-launch' "$f"; then rm -f -- "$f"; fi
  done
  if [[ -f "$unit" ]]; then rm -f -- "$unit"; fi
  if (( stopped )) && command -v systemctl >/dev/null; then
    if ! systemctl --user daemon-reload >/dev/null 2>&1; then
      [[ ! -S "$rt/bus" ]] ||
        env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
          systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi

  # Generated scripts are recognizable even in the earlier XDG ZIP without
  # the metadata record. Preserve unrelated scripts with coincidental names.
  # Both the current names and the pre-rename '.sh' variants are removed.
  for f in "$BIN_DIR/guix-env" "$BIN_DIR/guix-gui" \
           "$BIN_DIR/guix-daemon-launch" "$BIN_DIR/guix-desktop-sync" "$BIN_DIR/guix-pkg" \
           "$BIN_DIR/guix-env.sh" "$BIN_DIR/guix-gui.sh"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    case "${f##*/}" in
      guix-env|guix-env.sh)   grep -Fq 'GUIX_DAEMON_SOCKET' "$f" || continue ;;
      guix-gui|guix-gui.sh)   grep -Fq 'guix-env' "$f" || continue ;;
      guix-daemon-launch) grep -Fq 'guix-daemon' "$f" || continue ;;
      guix-desktop-sync) grep -Fq 'guix-bwrap-' "$f" || continue ;;
      guix-pkg)          grep -Fq 'guix-desktop-sync' "$f" || continue ;;
    esac
    rm -f -- "$f"
  done

  # Remove only the exact PATH stanza emitted by this installer, retaining
  # other custom PATH edits and shell configuration.
  local line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac'
  local rc temp
  for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" && ! -L "$rc" ]] || continue
    if grep -Fxq '# guix-rootless-bwrap PATH' "$rc"; then
      temp=$(mktemp "$rc.guix-uninstall.XXXXXXXX")
      awk -v expected="$line" '
        $0 == "# guix-rootless-bwrap PATH" {
          if (getline next_line) {
            if (next_line == expected) next
            print; print next_line; next
          }
          print; next
        }
        { print }
      ' "$rc" > "$temp"
      chmod --reference="$rc" "$temp"
      mv -f -- "$temp" "$rc"
    fi
  done

  # A Guix-generated profile symlink points to /var/guix, which is only
  # visible inside bwrap. Do not remove arbitrary user files at that name.
  if [[ -L "$HOME/.guix-profile" ]]; then
    local profile_target
    profile_target=$(readlink "$HOME/.guix-profile")
    if [[ "$profile_target" == /var/guix/profiles/* || "$profile_target" == "$PREFIX"/* ]]; then
      rm -f -- "$HOME/.guix-profile"
    else
      warn 'Preserving ~/.guix-profile: symlink target is not a recognized Guix profile.'
    fi
  fi

  # `guix pull` may install a second symlink representing the user's
  # current Guix version. Keep custom Guix configuration files untouched.
  local current_link current_target
  for current_link in "$HOME/.config/guix/current" "$config_home/guix/current"; do
    [[ -L "$current_link" ]] || continue
    current_target=$(readlink "$current_link")
    if [[ "$current_target" == /var/guix/profiles/*/current-guix* ||
          "$current_target" == "$PREFIX"/var/guix/profiles/*/current-guix* ]]; then
      rm -f -- "$current_link"
    fi
  done

  # Store subdirectories can be deliberately read-only; chmod only actual
  # directories (never follow store symlinks), then remove the whole prefix.
  for f in "$PREFIX" "$cache_home/guix"; do
    if [[ -L "$f" ]]; then warn "Preserving symlink at $f"; continue; fi
    [[ -d "$f" ]] || continue
    find -P "$f" -type d -exec chmod u+rwx {} + \
      || die "Could not make Guix directories deletable under $f"
    rm -rf -- "$f" || die "Failed to remove $f"
  done
  info 'UNINSTALL COMPLETE — rootless Guix, its installed packages, daemon and generated integrations were removed.'
  info 'User-owned Guix configuration (~/.config/guix) and downloaded archives were preserved.'
}

if (( ASSUME_YES && ! UNINSTALL )); then die '--yes is only valid with --uninstall'; fi
if (( UNINSTALL )); then uninstall_guix; exit 0; fi

# The installed helpers, service unit and desktop entries are plain files in
# the src/ tree beside this script, so they can be read and reviewed directly.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
SRC_DIR="$SCRIPT_DIR/src"
for required in bin/guix-env bin/guix-gui bin/guix-daemon-launch \
                bin/guix-desktop-sync bin/guix-pkg autostart/guix-desktop-sync.desktop \
                autostart/guix-daemon.desktop systemd/guix-daemon.service guix-releases.txt; do
  [[ -f "$SRC_DIR/$required" ]] || die "Missing src/$required beside install.sh; re-extract the full archive."
done

for cmd in bash bwrap tar sha256sum uname id mkdir chmod install awk find grep sed cp mv rm sleep; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing host command: $cmd"
done
if [[ $REUSE == 0 && -z $LOCAL_ARCHIVE ]] && ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
  die 'Install curl or wget on the host for downloading the Guix archive.'
fi

ARCH=${ARCH_OVERRIDE:-$(uname -m)}
case "$ARCH" in
  x86_64|amd64)
    if [[ -z "$ARCH_OVERRIDE" ]] && command -v getconf >/dev/null && [[ $(getconf LONG_BIT 2>/dev/null || true) == 32 ]]; then
      ARCH=i686
    else
      ARCH=x86_64
    fi
    ;;
  i?86) ARCH=i686 ;;
  armhf|armv[6-8]l|armv[6-8]hl) ARCH=armhf ;;
  aarch64|arm64) ARCH=aarch64 ;;
  powerpc64le|ppc64le) ARCH=powerpc64le ;;
  riscv64) ARCH=riscv64 ;;
  *) die "Unsupported architecture: '$ARCH'. See --help." ;;
esac

# The official archive filenames and SHA-256 values from GNU's Guix 1.5.0
# release announcement (Jan 23, 2026) are data, not code, and live in
# src/guix-releases.txt for direct human verification.
release=$(awk -v arch="$ARCH" '$1 == arch { print $2 " " $3; exit }' "$SRC_DIR/guix-releases.txt")
[[ -n $release ]] || die "No pinned Guix archive for architecture '$ARCH' in src/guix-releases.txt."
FILE=${release%% *}
SHA256=${release#* }
[[ $FILE == guix-binary-1.5.0.*-linux.tar.xz ]] || die "Unexpected archive filename in src/guix-releases.txt: $FILE"
[[ $SHA256 =~ ^[0-9a-f]{64}$ ]] || die "Invalid SHA-256 for '$ARCH' in src/guix-releases.txt: $SHA256"
info "Architecture: $ARCH; Guix archive: $FILE"
info "Install location: $PREFIX"

# Fail early on hosts that cannot launch a rootless bwrap namespace.
if ! bwrap --share-net --ro-bind / / -- /bin/true >/dev/null 2>&1; then
  die 'Bubblewrap cannot create a namespace on this host. Check bwrap installation and unprivileged user-namespace policy.'
fi

if [[ $REUSE == 0 ]]; then
  if [[ -e "$PREFIX/gnu/store" || -e "$PREFIX/var/guix" ]]; then
    die "Existing Guix data found in $PREFIX. Use --reuse (does not overwrite), or back it up and choose a fresh user."
  fi
  mkdir -p "$PREFIX"
  TEMP_DIR=$(mktemp -d "$PREFIX/.install-tmp.XXXXXXXX")
  trap 'rm -rf -- "${TEMP_DIR:-/nonexistent}"' EXIT
  if [[ -n "$LOCAL_ARCHIVE" ]]; then
    [[ -f "$LOCAL_ARCHIVE" ]] || die "Archive not found: $LOCAL_ARCHIVE"
    ARCHIVE=$LOCAL_ARCHIVE
  else
    ARCHIVE="$TEMP_DIR/$FILE"
    URL="$BASE_URL/$FILE"
    info "Downloading $URL"
    if command -v curl >/dev/null; then
      curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$ARCHIVE" "$URL" || die 'Download failed.'
    else
      wget --output-document="$ARCHIVE" "$URL" || die 'Download failed.'
    fi
  fi
  info 'Verifying official SHA-256 checksum'
  printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum --check --status \
    || die 'Checksum mismatch. Refusing to extract the archive.'
  info 'Extracting as current user; keeping Guix store objects read-only'
  tar -xJf "$ARCHIVE" -C "$PREFIX" --no-same-owner || die 'Archive extraction failed.'
fi

[[ -d "$PREFIX/gnu/store" && -d "$PREFIX/var/guix" ]] || die 'Expected gnu/store and var/guix directories not found.'
chmod u+w "$PREFIX/gnu/store" "$PREFIX/var/guix"
install -d -m 700 "$PREFIX/etc/guix" "$PREFIX/var/guix/daemon-socket"
# Respect non-default XDG application and autostart directories.
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$BIN_DIR" "$XDG_DATA_HOME/applications" "$XDG_CONFIG_HOME/autostart"
# Record resolved XDG paths for a later uninstall, including non-default XDG homes.
cat > "$PREFIX/.guix-bwrap-installer" <<EOF
guix-rootless-bwrap-v1
XDG_DATA_HOME=$XDG_DATA_HOME
XDG_CONFIG_HOME=$XDG_CONFIG_HOME
XDG_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
EOF

info 'Creating Bubblewrap command wrappers'
install -m 755 "$SRC_DIR/bin/guix-env"        "$BIN_DIR/guix-env"
install -m 755 "$SRC_DIR/bin/guix-gui"        "$BIN_DIR/guix-gui"
install -m 755 "$SRC_DIR/bin/guix-daemon-launch" "$BIN_DIR/guix-daemon-launch"
install -m 755 "$SRC_DIR/bin/guix-desktop-sync"  "$BIN_DIR/guix-desktop-sync"
install -m 755 "$SRC_DIR/bin/guix-pkg"           "$BIN_DIR/guix-pkg"

info 'Checking the Guix executable'
"$BIN_DIR/guix-env" guix --version | sed -n '1p'

render_template "$SRC_DIR/autostart/guix-desktop-sync.desktop" \
  "$XDG_CONFIG_HOME/autostart/guix-desktop-sync.desktop"

# Only append; never replace an existing shell configuration file.
path_line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac'
add_path_line() {
  local rc=$1
  if ! grep -Fq '# guix-rootless-bwrap PATH' "$rc" 2>/dev/null; then
    { printf '\n# guix-rootless-bwrap PATH\n%s\n' "$path_line"; } >> "$rc"
  fi
}
add_path_line "$HOME/.profile"
case "${SHELL:-}" in
  */bash) add_path_line "$HOME/.bashrc" ;;
  */zsh)  add_path_line "$HOME/.zshrc" ;;
esac

info 'Configuring daemon startup'
mkdir -p "$XDG_CONFIG_HOME/systemd/user"
install -m 644 "$SRC_DIR/systemd/guix-daemon.service" \
  "$XDG_CONFIG_HOME/systemd/user/guix-daemon.service"

started=0
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user daemon-reload >/dev/null 2>&1 &&
     systemctl --user enable --now guix-daemon.service >/dev/null 2>&1; then
    started=1
    info 'Enabled systemd user daemon service.'
  else
    # The Steam Frame's KDE desktop can have a different runtime bus from
    # the outer systemd user session. Redirect just these systemctl calls.
    rt="/run/user/$(id -u)"
    if [[ -S "$rt/bus" ]] &&
       env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
         systemctl --user daemon-reload >/dev/null 2>&1 &&
       env XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus" \
         systemctl --user enable --now guix-daemon.service >/dev/null 2>&1; then
      started=1
      info 'Enabled systemd user daemon service via the outer user bus.'
    fi
  fi
fi
if (( ! started )); then
  warn 'No usable systemd user manager; using graphical-session autostart instead.'
  render_template "$SRC_DIR/autostart/guix-daemon.desktop" \
    "$XDG_CONFIG_HOME/autostart/guix-daemon.desktop"
  nohup "$BIN_DIR/guix-daemon-launch" > "$PREFIX/var/guix/daemon.log" 2>&1 < /dev/null &
else
  # Remove an old fallback autostart file generated by this installer.
  if [[ -f "$XDG_CONFIG_HOME/autostart/guix-daemon.desktop" ]] &&
     grep -q 'Guix Daemon (Rootless)' "$XDG_CONFIG_HOME/autostart/guix-daemon.desktop"; then
    rm -f "$XDG_CONFIG_HOME/autostart/guix-daemon.desktop"
  fi
fi

info 'Waiting for Guix daemon socket'
ready=0
for ((i=0; i<20; i++)); do
  if "$BIN_DIR/guix-env" guix gc --list-roots >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if (( ! ready )); then
  die "Daemon did not respond. Inspect: journalctl --user -u guix-daemon.service -n 50; or $PREFIX/var/guix/daemon.log"
fi
info 'Authorizing official Guix substitute-server signing keys'
"$BIN_DIR/guix-env" /bin/bash -c '
  set -e
  keydir=/var/guix/profiles/per-user/root/current-guix/share/guix
  for name in ci.guix.gnu.org bordeaux.guix.gnu.org; do
    key="$keydir/$name.pub"
    [[ -r "$key" ]] || { echo "Missing Guix public key: $key" >&2; exit 1; }
    guix archive --authorize < "$key"
  done
'

if (( ! NO_EXAMPLES )); then
  info 'Installing hello and xterm (may download GUI dependencies)'
  "$BIN_DIR/guix-env" guix install hello xterm
  info 'Verifying hello'
  "$BIN_DIR/guix-env" "$HOME/.guix-profile/bin/hello"
fi
if (( WITH_GEANY )); then
  info 'Installing Geany (potentially hundreds of megabytes of GTK dependencies)'
  "$BIN_DIR/guix-env" guix install geany
fi

info 'Synchronizing XDG desktop entries'
"$BIN_DIR/guix-desktop-sync"

info 'INSTALLATION COMPLETE'
cat <<EOF
Guix data:       $PREFIX
Wrapper:         $BIN_DIR/guix-env
GUI wrapper:     $BIN_DIR/guix-gui
Package helper:  $BIN_DIR/guix-pkg

Current shell:   export PATH="\$HOME/.local/bin:\$PATH"
Guix version:    guix-env guix --version
Install package: guix-pkg install geany
GUI test:        guix-gui xterm      (from your graphical desktop)
Resync launchers: guix-desktop-sync

The daemon starts through systemd --user if available, otherwise XDG
session autostart. See README.md for requirements and troubleshooting.
EOF
