#!/usr/bin/env bash
# rhythm-kiosk :: one-shot system setup. Run ONCE after a stock Debian install
# (see INSTALL.md step 1 for the three install-time caveats), from this folder:
#
#     sudo ./rhythm-kiosk-installer.sh
#
# Automates everything INSTALL.md used to do by hand: packages, passwordless
# sudo, autologin, the supervised session chain, Openbox config, /opt layout
# (with EMPTY game/controller configs so the first-boot setup runs), udev and
# polkit rules, wallpaper. Safe to re-run. Reboot at the end lands in desktop
# mode with the guided first-boot setup open.
#
# RK_UNATTENDED=1 runs with no prompts and no reboot (used by the preseed
# late_command on the custom install ISO).
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
UNATTENDED="${RK_UNATTENDED:-0}"
KUSER="${RHYTHM_KIOSK_USER:-kiosk}"
KHOME="/home/$KUSER"
ROOT=/opt/rhythm-kiosk

say()  { printf '\n== %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask_yn() {
  local a
  while true; do
    printf '%s' "$1"
    read -r a || return 1
    case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | xargs)" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     echo "  Type y or n." ;;
    esac
  done
}

[[ $EUID -eq 0 ]] || fail "run with sudo: sudo $0"
for f in bin/boot-selector.sh bin/rhythm-launch bin/mapping-editor.sh bin/kiosk-alert \
         bin/games-pipemenu.sh bin/install-keybinds.sh openbox/autostart openbox/menu.xml \
         autologin.conf bash_profile-stanza xinitrc 010_kiosk-nopasswd \
         99-rhythm-perms.rules 49-rhythm-kiosk-udisks.rules; do
  [[ -f "$SRC/$f" ]] || fail "missing $SRC/$f -- run from the rhythm-kiosk folder"
done

echo "====================================================================="
echo " Rhythm Kiosk system setup"
echo " source : $SRC"
echo " user   : $KUSER"
echo "====================================================================="
if ! id "$KUSER" >/dev/null 2>&1; then
  fail "user '$KUSER' does not exist. Name the account '$KUSER' during the
       Debian install (INSTALL.md step 1), or set RHYTHM_KIOSK_USER."
fi
if [[ "$UNATTENDED" != "1" ]]; then
  ask_yn "Set this machine up as a rhythm kiosk? [y/n]: " || exit 0
fi

say "groups for $KUSER"
usermod -aG sudo,audio,video,input,plugdev "$KUSER" 2>/dev/null \
  || usermod -aG sudo,audio,video,input "$KUSER"

say "packages (network required)"
apt-get update
PKGS="openssh-server xserver-xorg xinit x11-xserver-utils x11-utils xfonts-base
openbox obconf lxterminal zenity pcmanfm dbus-x11 udiskie xwallpaper
usbutils unzip evtest joystick
pipewire-audio pipewire-alsa wireplumber alsa-utils
mesa-vulkan-drivers vulkan-tools
libxss1 libxcursor1 libxrandr2 libxinerama1 libxi6
fonts-dejavu unclutter-xfixes"
# In unattended mode (preseed late_command) wrap the big install in
# debconf-apt-progress so the d-i UI shows a real progress bar instead of
# sitting frozen for the several minutes this takes.
if [[ "$UNATTENDED" == "1" ]] && command -v debconf-apt-progress >/dev/null 2>&1; then
  # shellcheck disable=SC2086  # word-splitting the package list is the point
  debconf-apt-progress -- apt-get install -y $PKGS
else
  # shellcheck disable=SC2086  # word-splitting the package list is the point
  apt-get install -y $PKGS
fi
apt-get install -y polkitd 2>/dev/null || apt-get install -y policykit-1
apt-get install -y libfuse2t64 2>/dev/null || apt-get install -y libfuse2
apt-get install -y intel-microcode firmware-misc-nonfree 2>/dev/null \
  || echo "  (intel-microcode/firmware skipped -- enable the non-free-firmware apt component to add them later)"
say "passwordless sudo for $KUSER"
sed "s/^kiosk /$KUSER /" "$SRC/010_kiosk-nopasswd" > /etc/sudoers.d/010_kiosk-nopasswd
chmod 0440 /etc/sudoers.d/010_kiosk-nopasswd
visudo -c >/dev/null || fail "sudoers validation failed -- fix /etc/sudoers.d/010_kiosk-nopasswd"

say "autologin on tty1"
mkdir -p /etc/systemd/system/getty@tty1.service.d
sed "s/--autologin kiosk/--autologin $KUSER/" "$SRC/autologin.conf" \
  > /etc/systemd/system/getty@tty1.service.d/autologin.conf
systemctl daemon-reload

say "session chain for $KUSER"
install -o "$KUSER" -g "$KUSER" -m 0644 "$SRC/bash_profile-stanza" "$KHOME/.bash_profile"
install -o "$KUSER" -g "$KUSER" -m 0755 "$SRC/xinitrc" "$KHOME/.xinitrc"
install -d -o "$KUSER" -g "$KUSER" "$KHOME/.config/openbox"
install -o "$KUSER" -g "$KUSER" -m 0755 "$SRC/openbox/autostart" "$KHOME/.config/openbox/autostart"
install -o "$KUSER" -g "$KUSER" -m 0644 "$SRC/openbox/menu.xml" "$KHOME/.config/openbox/menu.xml"
install -o "$KUSER" -g "$KUSER" -m 0644 /etc/xdg/openbox/rc.xml "$KHOME/.config/openbox/rc.xml"

say "/opt/rhythm-kiosk"
mkdir -p "$ROOT/bin" "$ROOT/games"
install -m 0755 "$SRC"/bin/* "$ROOT/bin/"
ln -sf "$ROOT/bin/rhythm-launch" /usr/local/bin/rhythm-launch
# EMPTY configs: the guided first-boot setup builds the real ones.
[[ -f "$ROOT/games.conf" ]] || printf '# GAME_ID|DISPLAY_NAME|FULLSCREEN_CMD|WINDOWED_CMD\n' > "$ROOT/games.conf"
[[ -f "$ROOT/controllers.conf" ]] || printf '# VID:PID GAME_ID   (membership only; order lives in boot-order.conf)\n' > "$ROOT/controllers.conf"
if [[ ! -f "$ROOT/boot-order.conf" ]]; then
  printf '# Boot priority: one GAME_ID per line, TOP line boots first.\ndesktop\n' > "$ROOT/boot-order.conf"
fi
chmod 644 "$ROOT"/*.conf
[[ -f "$SRC/wallpaper.png" ]] && install -m 0644 "$SRC/wallpaper.png" "$ROOT/wallpaper.png"

say "keybinds into rc.xml"
sudo -u "$KUSER" -H "$ROOT/bin/install-keybinds.sh"

say "apt sources (normal Debian mirrors for online updates)"
# The offline-install ISO configures no network mirrors; add the standard ones
# so a connected machine updates like any Debian system. Offline they only
# produce harmless warnings; the bundled local repo (if present) still serves.
if ! grep -rqs "deb.debian.org/debian" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  cat > /etc/apt/sources.list.d/debian.list <<'SRC'
deb http://deb.debian.org/debian trixie main non-free-firmware
deb http://deb.debian.org/debian trixie-updates main non-free-firmware
deb http://security.debian.org/debian-security trixie-security main non-free-firmware
SRC
fi

say "udev + polkit rules"
install -m 0644 "$SRC/99-rhythm-perms.rules" /etc/udev/rules.d/99-rhythm-perms.rules
install -m 0644 "$SRC/49-rhythm-kiosk-udisks.rules" /etc/polkit-1/rules.d/49-rhythm-kiosk-udisks.rules
sed -i "s/subject.user == \"kiosk\"/subject.user == \"$KUSER\"/" /etc/polkit-1/rules.d/49-rhythm-kiosk-udisks.rules
udevadm control --reload-rules && udevadm trigger

echo ""
echo "====================================================================="
echo " Done. On reboot: autologin -> desktop -> guided first-boot setup"
echo " (install games, assign controllers, set the boot order there)."
echo "====================================================================="
if [[ "$UNATTENDED" != "1" ]]; then
  if ask_yn "Reboot now? [y/n]: "; then
    systemctl reboot
  fi
fi
