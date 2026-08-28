#!/usr/bin/env bash
# rhythm-kiosk :: install to /opt/rhythm-kiosk/bin/install-keybinds.sh  (chmod 755)
#
# One-time (idempotent) injection of the kiosk's TWO fixed keyboard functions
# into the user's rc.xml. Run as the kiosk user at install time (INSTALL step 9).
#
#   W-0 / W-Escape   kill the running game, back to the desktop
#                    (the only escape from a WEDGED fullscreen game)
#   W-m / Menu key   open the right-click menu from the keyboard
#
# W- = the Windows/Super key. These are deliberately NOT user-configurable;
# there is no other hotkey system (removed by decision 2026-08-26).
set -uo pipefail

ROOT="${RHYTHM_KIOSK_ROOT:-/opt/rhythm-kiosk}"
RCXML="${RHYTHM_RCXML:-$HOME/.config/openbox/rc.xml}"
BEGIN='<!-- rhythm-kiosk-keys BEGIN (fixed; installed by install-keybinds.sh) -->'
END='<!-- rhythm-kiosk-keys END -->'

[[ -w "$RCXML" ]] || { echo "install-keybinds: cannot write $RCXML (run as the kiosk user)" >&2; exit 1; }

xml="  <keybind key=\"W-0\"><action name=\"Execute\"><command>$ROOT/bin/rhythm-launch --kill</command></action></keybind>
  <keybind key=\"W-Escape\"><action name=\"Execute\"><command>$ROOT/bin/rhythm-launch --kill</command></action></keybind>
  <keybind key=\"W-m\"><action name=\"ShowMenu\"><menu>root-menu</menu></action></keybind>
  <keybind key=\"Menu\"><action name=\"ShowMenu\"><menu>root-menu</menu></action></keybind>
"
tmp="$RCXML.tmp.$$"
export _RK_XML="$xml"
if grep -qF -- "$BEGIN" "$RCXML"; then
  awk -v begin="$BEGIN" -v end="$END" '
    index($0, begin) { print begin; printf "%s", ENVIRON["_RK_XML"]; print end; skip=1; next }
    skip && index($0, end) { skip=0; next }
    !skip { print }
  ' "$RCXML" > "$tmp"
else
  awk -v begin="$BEGIN" -v end="$END" '
    /<\/keyboard>/ && !done { print begin; printf "%s", ENVIRON["_RK_XML"]; print end; done=1 }
    { print }
  ' "$RCXML" > "$tmp"
fi
if ! python3 -c "import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$tmp" 2>/dev/null; then
  echo "install-keybinds: result is not valid XML -- rc.xml left unchanged." >&2
  rm -f "$tmp"
  exit 1
fi
mv -f "$tmp" "$RCXML"

if [[ -n "${DISPLAY:-}" ]] && command -v openbox >/dev/null 2>&1; then
  openbox --reconfigure 2>/dev/null || true
fi
echo "install-keybinds: kiosk keybinds installed."
