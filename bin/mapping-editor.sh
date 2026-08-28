#!/usr/bin/env bash
#
# mapping-editor.sh
# INSTALL DESTINATION ON TARGET PC: /opt/rhythm-kiosk/bin/mapping-editor.sh   (chmod 755)
# Launched from the Openbox root menu ("Maintenance -> Mapping Editor") inside a terminal:
#     xterm -title "Rhythm Kiosk Mapping Editor" -e /opt/rhythm-kiosk/bin/mapping-editor.sh
#
# Interactive controller -> game mapping + game installer, modeled on Tyler's
# BetterDeploy.command flow (numbered list -> comma-separated selection -> prompts -> Y/N confirm).
#
# Deliberately PLAIN bash (no whiptail/dialog): drag-and-drop of an installer file onto the
# terminal window only works at a plain `read -r` prompt.
#
# The Openbox menu runs this as `x-terminal-emulator -e mapping-editor.sh`, so the window
# is destroyed the instant the script returns. An EXIT trap therefore holds the window open
# with a "Press Enter to close" prompt on EVERY exit path (normal finish, early abort, or
# error), so the user can read the final output. Set SKIP_EXIT_PAUSE=1 before returning from
# any future path that already ends at its own prompt, to avoid a double pause.
#
# Root writes: /opt/rhythm-kiosk is root-owned, so every write goes through sudo.
# The kiosk user gets passwordless sudo from /etc/sudoers.d/010_kiosk-nopasswd
# (the RetroPie 010_pi-nopasswd pattern). This script uses `sudo -n` ONLY -- it must
# never sit on a hidden password prompt inside a throwaway xterm. A start-up
# pre-flight fails loudly and names that file if sudo is not usable, and every root
# write checks its result so a failed write can never print a success message.
#
# Dry-run on a dev machine (point ROOT at a writable dir -- no sudo involved):
#     RHYTHM_KIOSK_ROOT=/tmp/rk RHYTHM_FAKE_LSUSB=./fake-lsusb.txt ./mapping-editor.sh
#
# Config formats written by this script:
#   controllers.conf : whitespace-separated  PRIORITY VID:PID GAME_ID   (lower priority wins)
#   games.conf       : pipe-separated        GAME_ID|DISPLAY_NAME|FULLSCREEN_CMD|WINDOWED_CMD
#   '#' comments and blank lines are ignored in both.

# -u only, deliberately no -e: this script is interactive and full of expected
# non-zero returns (aborted prompts, declined confirmations, probe greps).
set -u

# --- Paths (RHYTHM_KIOSK_ROOT override exists only for dry-run testing) --------------
ROOT="${RHYTHM_KIOSK_ROOT:-/opt/rhythm-kiosk}"
CONTROLLERS_CONF="$ROOT/controllers.conf"
GAMES_CONF="$ROOT/games.conf"
ORDER_CONF="$ROOT/boot-order.conf"
GAMES_DIR="$ROOT/games"

# --- Root-write helper ---------------------------------------------------------------
# Everything under /opt/rhythm-kiosk is root-owned; the kiosk user needs sudo to write it.
# A writable $ROOT (dry-run fixture, or a not-yet-created $ROOT under a writable parent)
# needs no sudo at all.
SUDO=""
if [[ -d "$ROOT" ]]; then
  [[ -w "$ROOT" ]] || SUDO="sudo"
else
  [[ -w "$(dirname "$ROOT")" ]] || SUDO="sudo"
fi

SUDOERS_FILE="/etc/sudoers.d/010_kiosk-nopasswd"

as_root() { if [[ -n "$SUDO" ]]; then sudo -n "$@"; else "$@"; fi; }

# --- Sudo pre-flight -----------------------------------------------------------------
# Runs before ANY work. `sudo -n` = non-interactive: it returns non-zero instead of
# prompting, which is the whole point -- a password prompt hidden inside the throwaway
# xterm looked like a hang, and writes then failed while the editor claimed success.
preflight_sudo() {
  [[ -z "$SUDO" ]] && return 0
  sudo -n true 2>/dev/null && return 0

  echo ""                                                                        >&2
  echo "====================================================================="   >&2
  echo " ERROR: sudo is not usable without a password — cannot continue."        >&2
  echo "====================================================================="   >&2
  echo "  $ROOT is not writable by $(id -un), so this editor needs sudo to"      >&2
  echo "  install games and to write games.conf / controllers.conf. It will"     >&2
  echo "  NEVER prompt for a password (an invisible prompt in this terminal is"  >&2
  echo "  exactly the silent failure this design forbids)."                      >&2
  echo ""                                                                        >&2
  echo "  MISSING (or broken) FILE:"                                             >&2
  echo "      $SUDOERS_FILE"                                                     >&2
  echo "  Its entire contents must be the single line:"                          >&2
  echo "      kiosk ALL=(ALL) NOPASSWD: ALL"                                     >&2
  echo ""                                                                        >&2
  echo "  Install it from a sudo-capable account (staging copy ships with this"  >&2
  echo "  project as 010_kiosk-nopasswd):"                                       >&2
  echo "      sudo install -o root -g root -m 0440 \\"                           >&2
  echo "           ~/rhythm-kiosk-staging/010_kiosk-nopasswd \\"                 >&2
  echo "           $SUDOERS_FILE"                                                >&2
  echo "      sudo visudo -c"                                                    >&2
  echo ""                                                                        >&2
  echo "  visudo -c MUST report 'parsed OK' before you log out — a syntactically">&2
  echo "  broken file in /etc/sudoers.d/ locks out sudo completely. Mode must be">&2
  echo "  0440 root:root, and the filename must contain no '.' or trailing '~'"  >&2
  echo "  or sudo ignores it. Then re-run this editor."                          >&2
  echo ""                                                                        >&2
  exit 1
}

# --- Loud write failure --------------------------------------------------------------
# Every root write is checked; nothing here ever fails quietly.
write_fail() { # write_fail <file> <what-was-being-done>
  echo ""                                                                        >&2
  echo "  ${C_W}!!! WRITE FAILED !!!${C_0}"                                                  >&2
  echo "      File   : $1"                                                       >&2
  echo "      Action : $2"                                                       >&2
  if [[ -n "$SUDO" ]]; then
    if sudo -n true 2>/dev/null; then
      echo "      sudo   : still works, so this is NOT a sudo problem."          >&2
      echo "               Check free space (df -h '$ROOT') and that the file"   >&2
      echo "               is not read-only or immutable (lsattr)."              >&2
    else
      echo "      sudo   : NO LONGER USABLE without a password."                 >&2
      echo "               Fix $SUDOERS_FILE (0440 root:root, one line:"         >&2
      echo "               'kiosk ALL=(ALL) NOPASSWD: ALL'), then 'sudo visudo -c'." >&2
    fi
  else
    echo "      Running without sudo (\$ROOT was writable): check permissions"   >&2
    echo "      on that file and free space (df -h '$ROOT')."                     >&2
  fi
  echo ""                                                                        >&2
  return 1
}

append_line() { # append_line <file> <line>  -> non-zero on write failure
  if ! printf '%s\n' "$2" | as_root tee -a "$1" >/dev/null; then
    write_fail "$1" "appending a line"
    return 1
  fi
}

ensure_files() {
  if ! as_root mkdir -p "$ROOT" "$GAMES_DIR" "$ROOT/bin"; then
    write_fail "$ROOT" "creating the kiosk directories ($ROOT, $GAMES_DIR, $ROOT/bin)"
    return 1
  fi
  if [[ ! -f "$CONTROLLERS_CONF" ]]; then
    append_line "$CONTROLLERS_CONF" "# VID:PID GAME_ID   (membership only; order lives in boot-order.conf)" || return 1
  fi
  if [[ ! -f "$GAMES_CONF" ]]; then
    append_line "$GAMES_CONF" "# GAME_ID|DISPLAY_NAME|FULLSCREEN_CMD|WINDOWED_CMD" || return 1
  fi
  if [[ ! -f "$ORDER_CONF" ]]; then
    append_line "$ORDER_CONF" "# Boot priority: one GAME_ID per line, TOP line boots first." || return 1
  fi
}

# --- Small utilities -----------------------------------------------------------------
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

pause_enter() { local _x; read -r -p "Press Enter to continue... " _x || true; }

# ask_yn <prompt> -> 0 for yes, 1 for no. Tyler's rule: a BLANK Enter is never
# a silent default -- every y/n prompt requires an explicit answer.
ask_yn() {
  local _ans
  while true; do
    echo -n "$1"
    read -r _ans || return 1
    _ans="$(lower "$(trim "$_ans")")"
    case "$_ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      "")    echo "  Blank entry -- type y or n." ;;
      *)     echo "  Invalid entry: '$_ans' -- type y or n." ;;
    esac
  done
}

# --- Keep the terminal window readable on every exit path ----------------------------
# The Openbox menu launches this in a throwaway terminal that dies with the script.
SKIP_EXIT_PAUSE="${SKIP_EXIT_PAUSE:-0}"
# During firstboot, per-game boot-order placement is deferred to its own final
# step so several games and controllers can be configured in one pass.
FIRSTBOOT_MODE=0

# Colors: section headers cyan, option numbers yellow, warnings red. Active
# only on a real terminal (fixtures/pipes stay plain); NO_COLOR respected.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_H=$'\e[1;36m'; C_N=$'\e[1;33m'; C_W=$'\e[1;31m'; C_0=$'\e[0m'
else
  C_H=""; C_N=""; C_W=""; C_0=""
fi
exit_pause() {
  local rc=$?
  if [[ "$SKIP_EXIT_PAUSE" -eq 0 ]]; then
    echo ""
    printf 'Press Enter to close this window... '
    local _x
    read -r _x || true
    echo ""
  fi
  return "$rc"
}
trap exit_pause EXIT

# Strip the quoting a terminal adds when a file is dragged onto the window.
unquote_path() {
  local p; p="$(trim "$1")"
  if [[ ${#p} -ge 2 && ${p:0:1} == "'" && ${p: -1} == "'" ]]; then
    p="${p:1:${#p}-2}"
  elif [[ ${#p} -ge 2 && ${p:0:1} == '"' && ${p: -1} == '"' ]]; then
    p="${p:1:${#p}-2}"
  else
    # unquoted drops use backslash escapes: "My\ Game\ Installer.AppImage"
    p="$(printf '%s' "$p" | sed -e 's/\\\(.\)/\1/g')"
  fi
  p="$(trim "$p")"
  # Some terminals paste a dropped file as a file:// URI; strip and %-decode it.
  if [[ "$p" == file://* ]]; then
    p="${p#file://}"
    p="$(printf '%b' "${p//\%/\\x}")"
  fi
  # shellcheck disable=SC2088  # testing for a literal leading ~/ in pasted input, then expanding it
  [[ ${p:0:2} == "~/" ]] && p="$HOME/${p:2}"
  printf '%s' "$p"
}

# --- Config readers ------------------------------------------------------------------
# Non-comment, non-blank lines only.
conf_lines() { # conf_lines <file>
  [[ -f "$1" ]] || return 0
  # tr -d '\r': tolerate CRLF confs (edited on Windows) in every reader downstream
  grep -vE '^[[:space:]]*(#|$)' "$1" | tr -d '\r' || true
}

game_exists() { # game_exists <game-id>
  conf_lines "$GAMES_CONF" | awk -F'|' -v g="$1" '$1==g {found=1} END {exit !found}'
}

game_display_name() { # game_display_name <game-id>
  conf_lines "$GAMES_CONF" | awk -F'|' -v g="$1" '$1==g {print $2; exit}'
}

mapping_for_vidpid() { # -> GAME_ID or empty
  conf_lines "$CONTROLLERS_CONF" | awk -v id="$1" '$1==id {print $2; exit}'
}

# Rewrite one controllers.conf line in place (temp file + mv), matched on VID:PID.
# The temp file is created beside the target so the mv is atomic and stays root-owned.
replace_controller_line() { # replace_controller_line <vid:pid> <new line>
  local tmp="$CONTROLLERS_CONF.tmp.$$"
  awk -v id="$1" -v newline="$2" '
    { sub(/\r$/, "") }                       # tolerate CRLF confs
    /^[[:space:]]*(#|$)/ { print; next }
    $1 == id { if (!done) { print newline; done=1 } ; next }
    { print }
    END { if (!done) print newline }
  ' "$CONTROLLERS_CONF" | as_root tee "$tmp" >/dev/null
  # PIPESTATUS: a failed awk with a successful tee would silently truncate the conf.
  if [[ "${PIPESTATUS[0]}" -ne 0 || "${PIPESTATUS[1]}" -ne 0 ]]; then
    as_root rm -f "$tmp" 2>/dev/null
    write_fail "$CONTROLLERS_CONF" "rewriting one mapping line via $tmp (original left untouched)"
    return 1
  fi
  if ! as_root mv -f "$tmp" "$CONTROLLERS_CONF"; then
    write_fail "$CONTROLLERS_CONF" "moving $tmp into place (the new text is still in that .tmp file)"
    return 1
  fi
}

# Rewrite one games.conf line in place (temp file + mv), matched on GAME_ID.
replace_game_line() { # replace_game_line <game-id> <new line>
  local tmp="$GAMES_CONF.tmp.$$"
  awk -F'|' -v g="$1" -v newline="$2" '
    { sub(/\r$/, "") }                       # tolerate CRLF confs
    /^[[:space:]]*(#|$)/ { print; next }
    $1 == g { if (!done) { print newline; done=1 } ; next }
    { print }
    END { if (!done) print newline }
  ' "$GAMES_CONF" | as_root tee "$tmp" >/dev/null
  if [[ "${PIPESTATUS[0]}" -ne 0 || "${PIPESTATUS[1]}" -ne 0 ]]; then
    as_root rm -f "$tmp" 2>/dev/null
    write_fail "$GAMES_CONF" "rewriting one game line via $tmp (original left untouched)"
    return 1
  fi
  if ! as_root mv -f "$tmp" "$GAMES_CONF"; then
    write_fail "$GAMES_CONF" "moving $tmp into place (the new text is still in that .tmp file)"
    return 1
  fi
}

# =====================================================================================
# FUNCTION 1 — Enumerate USB devices and let the user select one or more
# =====================================================================================
DEV_ID=()      # VID:PID
DEV_DESC=()    # human-readable description from lsusb
DEV_STATE=()   # "new" or "mapped"
DEV_GAME=()    # game-id if mapped

# usb_is_storage_or_hub <vid:pid> -- true when every USB interface the device
# exposes is mass-storage (class 08) or hub (09). Interface classes are the
# USB standard's own "what kind of thing is this" field (HID controllers are
# 03), read from sysfs -- so USB sticks/drives never appear as mappable
# controllers. Unknown devices (no sysfs match, e.g. fixture runs) are KEPT.
usb_is_storage_or_hub() {
  local vid=${1%%:*} pid=${1##*:} d i cls found=0
  for d in /sys/bus/usb/devices/*/; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    [[ "$(cat "$d/idVendor" 2>/dev/null)" == "$vid" ]] || continue
    [[ "$(cat "$d/idProduct" 2>/dev/null)" == "$pid" ]] || continue
    for i in "$d"*/bInterfaceClass; do
      [[ -f "$i" ]] || continue
      found=1
      cls="$(cat "$i" 2>/dev/null)"
      case "$cls" in
        08|09) ;;          # storage / hub: not a controller
        *) return 1 ;;     # any other interface: keep the device
      esac
    done
  done
  [[ $found -eq 1 ]]
}

raw_lsusb() {
  if [[ -n "${RHYTHM_FAKE_LSUSB:-}" ]]; then
    if [[ ! -r "$RHYTHM_FAKE_LSUSB" ]]; then
      echo "ERROR: RHYTHM_FAKE_LSUSB set but not readable: $RHYTHM_FAKE_LSUSB" >&2
      return 1
    fi
    cat "$RHYTHM_FAKE_LSUSB"
  elif command -v lsusb >/dev/null 2>&1; then
    lsusb
  else
    echo "ERROR: lsusb not found (install the 'usbutils' package)." >&2
    return 1
  fi
}

enumerate_devices() {
  DEV_ID=(); DEV_DESC=(); DEV_STATE=(); DEV_GAME=()

  local -a new_id=() new_desc=() map_id=() map_desc=() map_game=()
  local -a seen=()
  local line id desc game

  while IFS= read -r line; do
    # Expected: Bus 001 Device 004: ID 1430:4748 RedOctane Guitar Hero X-plorer
    [[ "$line" =~ ID[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})[[:space:]]*(.*)$ ]] || continue
    id="$(lower "${BASH_REMATCH[1]}")"
    desc="$(trim "${BASH_REMATCH[2]}")"
    [[ -z "$desc" ]] && desc="(no description)"

    # Skip hubs and root hubs — never a game controller.
    printf '%s' "$desc" | grep -qiE '(^|[^a-z])hub([^a-z]|$)' && continue
    # Skip mass-storage devices (USB sticks/drives): install sources, not controllers.
    usb_is_storage_or_hub "$id" && continue

    # De-dup: mapping is by VID:PID, so identical twin devices are one entry.
    local dup=0 s
    for s in ${seen[@]+"${seen[@]}"}; do [[ "$s" == "$id" ]] && dup=1 && break; done
    [[ $dup -eq 1 ]] && continue
    seen+=("$id")

    game="$(mapping_for_vidpid "$id")"
    if [[ -n "$game" ]]; then
      map_id+=("$id"); map_desc+=("$desc"); map_game+=("$game")
    else
      new_id+=("$id"); new_desc+=("$desc")
    fi
  done < <(raw_lsusb)

  # UNCONFIGURED devices first...
  local i
  for i in "${!new_id[@]}"; do
    DEV_ID+=("${new_id[$i]}"); DEV_DESC+=("${new_desc[$i]}")
    DEV_STATE+=("new"); DEV_GAME+=("")
  done

  # ...then already-known devices, in controllers.conf order.
  for i in "${!map_id[@]}"; do
    DEV_ID+=("${map_id[$i]}"); DEV_DESC+=("${map_desc[$i]}")
    DEV_STATE+=("mapped"); DEV_GAME+=("${map_game[$i]}")
  done
}

print_device_list() {
  local i n label
  echo "${C_H}--- Connected USB Devices ---${C_0}"
  if [[ ${#DEV_ID[@]} -eq 0 ]]; then
    echo "No non-hub USB devices found."
    return
  fi
  local printed_header_new=0 printed_header_known=0
  for i in "${!DEV_ID[@]}"; do
    n=$(( i + 1 ))
    if [[ "${DEV_STATE[$i]}" == "new" ]]; then
      if [[ $printed_header_new -eq 0 ]]; then echo "  [ UNCONFIGURED ]"; printed_header_new=1; fi
      label="NEW"
      printf "  ${C_N}%2d)${C_0} %s  %-46s  [%s]\n" "$n" "${DEV_ID[$i]}" "${DEV_DESC[$i]:0:46}" "$label"
    else
      if [[ $printed_header_known -eq 0 ]]; then echo "  [ ALREADY MAPPED ]"; printed_header_known=1; fi
      label="mapped -> ${DEV_GAME[$i]}"
      printf "  ${C_N}%2d)${C_0} %s  %-46s  [%s]\n" "$n" "${DEV_ID[$i]}" "${DEV_DESC[$i]:0:46}" "$label"
    fi
  done
  echo ""
}

SELECTED=()   # indices into DEV_*

select_devices() {
  SELECTED=()
  local input sel index

  echo -n "Select the controller(s) to map (comma-separated numbers, or 'all'): "
  read -r input || return 1
  input="$(trim "$input")"

  if [[ "$(lower "$input")" == "all" ]]; then
    for index in "${!DEV_ID[@]}"; do SELECTED+=("$index"); done
    return 0
  fi

  # IFS as a prefix on `read` applies to that one command only; no save/restore needed.
  IFS=',' read -ra selections <<< "$input"
  for sel in ${selections[@]+"${selections[@]}"}; do
    sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
    [[ -z "$sel" ]] && continue
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
      index=$(( sel - 1 ))
      if [[ "$index" -ge 0 && "$index" -lt "${#DEV_ID[@]}" ]]; then
        # ignore duplicates in the user's input
        local already=0 s2
        for s2 in ${SELECTED[@]+"${SELECTED[@]}"}; do [[ "$s2" == "$index" ]] && already=1 && break; done
        [[ $already -eq 0 ]] && SELECTED+=("$index")
      else
        echo "Invalid device number: $sel. Skipping."
      fi
    else
      echo "Invalid input: $sel. Please enter numbers or 'all'."
    fi
  done

  [[ ${#SELECTED[@]} -gt 0 ]]
}

# =====================================================================================
# FUNCTION 2 — Installer intake (drag-and-drop) and install
# =====================================================================================
INSTALLER_PATH=""

intake_installer() {
  INSTALLER_PATH=""
  local raw resolved mode have_picker=0
  local instdir="${RHYTHM_INSTALLERS_DIR:-$HOME/installers}"
  mkdir -p -- "$instdir" 2>/dev/null || true
  # A plugged-in USB stick (auto-mounted under /media) is the likelier source:
  # start the picker on the newest mount. An explicit override still wins.
  if [[ -z "${RHYTHM_INSTALLERS_DIR:-}" ]]; then
    local media
    # shellcheck disable=SC2012  # ls -t picks the newest mount; newline labels are not a realistic threat
    media="$(ls -1dt /media/"$(id -un)"/*/ 2>/dev/null | head -1)"
    [[ -n "$media" ]] && instdir="$media"
  fi
  [[ -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1 && have_picker=1

  echo "${C_H}--- Game Installer ---${C_0}"
  echo "Supported: .AppImage  .deb  .tar.gz / .tar.xz / .tar.bz2  .zip  .sh / .run"
  echo "installers, or a bare executable."
  echo ""

  while true; do
    # ---- how does the user want to point at the file? ----
    raw=""
    if [[ $have_picker -eq 1 ]]; then
      echo "  ${C_N}1)${C_0} Browse for the installer file"
      echo "  ${C_N}2)${C_0} Type or paste its path"
      echo "  ${C_N}q)${C_0} Cancel"
      echo -n "Choose [1/2/q]: "
      read -r mode || return 1
      mode="$(lower "$(trim "$mode")")"
      case "$mode" in
        q|quit|exit) return 1 ;;
        1)
          raw="$(zenity --file-selection --title="Choose the game installer" \
                        --filename="$instdir/" 2>/dev/null)" || true
          if [[ -z "$raw" ]]; then
            echo "  No file chosen."
            echo ""
            continue
          fi
          ;;
        2)  ;;   # falls through to the path prompt below
        "") echo "  Blank entry -- choose 1, 2 or q."; echo ""; continue ;;
        *)  echo "  Invalid choice: $mode"; echo ""; continue ;;
      esac
    fi

    if [[ -z "$raw" ]]; then
      echo -n "Installer file path ('q' = cancel): "
      read -r raw || return 1
      raw="$(trim "$raw")"
      case "$(lower "$raw")" in
        q|quit|exit) return 1 ;;
        "")          echo "  Blank entry -- type a path, or 'q'."; echo ""; continue ;;
      esac
    fi

    resolved="$(unquote_path "$raw")"
    if [[ -d "$resolved" ]]; then
      echo "  That is a directory, not an installer file. Try again."
      echo ""
      continue
    fi
    if [[ ! -f "$resolved" ]]; then
      echo "  File not found: $resolved"
      echo ""
      continue
    fi
    resolved="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    INSTALLER_PATH="$resolved"
    echo ""
    echo "  Resolved path : $INSTALLER_PATH"
    echo "  Size          : $(du -h "$INSTALLER_PATH" 2>/dev/null | awk '{print $1}')"
    echo ""
    pause_enter
    return 0
  done
}

# --- Install the package into /opt/rhythm-kiosk/games/<game-id>/ ---------------------
INSTALL_DIR=""
SUGGESTED_BIN=""

install_package() { # install_package <installer-path> <game-id>
  local src="$1" gid="$2" base lc
  INSTALL_DIR="$GAMES_DIR/$gid"
  SUGGESTED_BIN=""
  base="$(basename "$src")"
  lc="$(lower "$base")"

  echo "--- Installing '$base' as game id '$gid' ---"
  if ! as_root mkdir -p "$INSTALL_DIR"; then
    write_fail "$INSTALL_DIR" "creating the install directory"
    return 1
  fi

  case "$lc" in
    *.appimage)
      if ! as_root cp -f "$src" "$INSTALL_DIR/$base" || ! as_root chmod +x "$INSTALL_DIR/$base"; then
        write_fail "$INSTALL_DIR/$base" "copying the AppImage and making it executable"
        return 1
      fi
      SUGGESTED_BIN="$INSTALL_DIR/$base"
      echo "  AppImage copied and made executable."
      echo "  NOTE: AppImages need FUSE ('libfuse2' on Debian). If it refuses to run,"
      echo "        extract it once with:  $INSTALL_DIR/$base --appimage-extract"
      ;;
    *.deb)
      echo "  Installing system package with apt (needs sudo)..."
      if as_root apt-get install -y "$src"; then
        echo "  apt-get install succeeded."
      elif as_root dpkg -i "$src"; then
        echo "  dpkg -i succeeded."
        echo "  NOTE: if dpkg reported missing dependencies, run:  sudo apt-get -f install"
      else
        echo "  ${C_W}WARNING:${C_0} package install FAILED. Fix dependencies manually, then re-run this editor."
      fi
      # A .deb installs into system paths, not into $INSTALL_DIR — guess the binary from dpkg.
      local pkgname
      pkgname="$(dpkg-deb -f "$src" Package 2>/dev/null || true)"
      if [[ -n "$pkgname" ]]; then
        SUGGESTED_BIN="$(dpkg -L "$pkgname" 2>/dev/null | grep -E '^/usr/(local/)?(bin|games)/' | head -n1 || true)"
      fi
      echo "  NOTE: system package — nothing was placed in $INSTALL_DIR."
      ;;
    *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar)
      echo "  Extracting archive into $INSTALL_DIR ..."
      as_root tar -xf "$src" -C "$INSTALL_DIR" || echo "  ${C_W}WARNING:${C_0} extraction reported an error."
      ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        echo "  Extracting zip into $INSTALL_DIR ..."
        as_root unzip -o -q "$src" -d "$INSTALL_DIR" || echo "  ${C_W}WARNING:${C_0} extraction reported an error."
      else
        echo "  ERROR: 'unzip' is not installed.  sudo apt-get install unzip"
      fi
      ;;
    *.sh|*.run)
      # Self-extracting installer (GOG / MojoSetup / makeself style). These ask
      # their own questions, so run it interactively right here.
      echo "  This is a self-extracting installer. It will now RUN and ask its own"
      echo "  questions. When it asks WHERE to install, use exactly:"
      echo "      $INSTALL_DIR"
      pause_enter
      as_root mkdir -p "$INSTALL_DIR"
      as_root chown "$(id -un)" "$INSTALL_DIR"
      if ! RHYTHM_INSTALL_DIR="$INSTALL_DIR" sh -- "$src"; then
        echo "  ${C_W}WARNING:${C_0} the installer exited with an error."
      fi
      if [[ -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
        echo "  ${C_W}WARNING:${C_0} $INSTALL_DIR is empty. The game may have installed somewhere"
        echo "  else; you can still type its launch command at the next step."
      fi
      ;;
    *)
      # Bare executable (or an unknown blob we treat as one).
      if ! as_root cp -f "$src" "$INSTALL_DIR/$base" || ! as_root chmod +x "$INSTALL_DIR/$base"; then
        write_fail "$INSTALL_DIR/$base" "copying the executable and chmod +x"
        return 1
      fi
      SUGGESTED_BIN="$INSTALL_DIR/$base"
      echo "  Copied as a bare executable and chmod +x."
      ;;
  esac
  echo ""
}

# Best-guess the launch binary inside the installed directory, then let the user confirm.
pick_launch_binary() { # pick_launch_binary <game-id>  -> echoes chosen command
  local gid="$1"
  local -a cands=()
  local c n sel

  if [[ -n "$SUGGESTED_BIN" && -e "$SUGGESTED_BIN" ]]; then
    cands+=("$SUGGESTED_BIN")
  fi
  if [[ -d "$INSTALL_DIR" ]]; then
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      [[ "$c" == "${SUGGESTED_BIN:-}" ]] && continue
      cands+=("$c")
    done < <(find "$INSTALL_DIR" -maxdepth 3 -type f -perm -u+x \
               ! -name '*.so' ! -name '*.so.*' ! -name '*.txt' ! -name '*.md' \
               ! -name '*.png' ! -name '*.dll' 2>/dev/null | sort | head -n 15)
  fi

  {
    echo "${C_H}--- Launch Command ---${C_0}"
    if [[ ${#cands[@]} -gt 0 ]]; then
      echo "Executable candidates found:"
      for n in "${!cands[@]}"; do printf "  ${C_N}%2d)${C_0} %s\n" "$(( n + 1 ))" "${cands[$n]}"; done
    else
      echo "No executable candidates were auto-detected."
    fi
    echo "   ${C_N}0)${C_0} Type the command myself"
    echo ""
  } >&2

  while true; do
    printf 'Choose the launch binary [number, or 0 to type it]: ' >&2
    read -r sel || { printf '%s' "/bin/true"; return; }
    sel="$(printf '%s' "$sel" | tr -d '[:space:]')"
    if [[ "$sel" == "0" ]]; then
      printf 'Full launch command for %s: ' "$gid" >&2
      read -r c || c=""
      c="$(trim "$c")"
      if [[ -n "$c" ]]; then printf '%s' "$c"; return; fi
      echo "  Empty command. Try again." >&2
      continue
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && [[ $(( sel - 1 )) -lt ${#cands[@]} ]]; then
      printf '%s' "${cands[$(( sel - 1 ))]}"
      return
    fi
    echo "  Invalid choice: $sel" >&2
  done
}

# Game picker (FUNCTION 2): the primary flow choice. Lists installed games and,
# at the BOTTOM, an "Install a NEW game" entry (Tyler's spec). Prints the chosen
# GAME_ID -- or the literal token NEW -- on stdout; returns 1 on 'q'/EOF.
choose_game() {
  local -a ids=() names=()
  local line id name sel i ninstall
  while IFS= read -r line; do
    IFS='|' read -r id name _ <<<"$line"
    id="$(trim "${id-}")"; name="$(trim "${name-}")"
    [[ -n "$id" ]] || continue
    [[ -n "$name" ]] || name="$id"
    ids+=("$id"); names+=("$name")
  done < <(conf_lines "$GAMES_CONF")
  ninstall=$(( ${#ids[@]} + 1 ))

  {
    echo "${C_H}--- Assign the controller(s) to which game? ---${C_0}"
    for i in "${!ids[@]}"; do printf "  ${C_N}%2d)${C_0} %s (%s)\n" "$(( i + 1 ))" "${names[$i]}" "${ids[$i]}"; done
    printf "  ${C_N}%2d)${C_0} Install a NEW game...\n" "$ninstall"
    echo ""
  } >&2

  while true; do
    printf "Select a game [number or game id, 'q' to quit]: " >&2
    read -r sel || return 1
    sel="$(lower "$(trim "$sel")")"
    case "$sel" in
      q|quit|exit) return 1 ;;
      "")          echo "  Blank entry -- pick a number from the list, or 'q' to quit." >&2; continue ;;
    esac
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
      if (( 10#$sel == ninstall )); then printf 'NEW'; return 0; fi
      if (( 10#$sel >= 1 && 10#$sel <= ${#ids[@]} )); then printf '%s' "${ids[$(( 10#$sel - 1 ))]}"; return 0; fi
      echo "  Invalid number: $sel" >&2
      continue
    fi
    for i in "${!ids[@]}"; do
      if [[ "${ids[$i]}" == "$sel" ]]; then printf '%s' "$sel"; return 0; fi
    done
    echo "  '$sel' is not an existing game id. Pick from the list, or 'q' to quit." >&2
  done
}

# =====================================================================================
# Config writing
# =====================================================================================
# Every write below is checked; the success echo happens ONLY after the write
# actually landed. (The old version echoed success unconditionally, so a failed
# sudo write reported "games.conf <- ..." for a line that was never written.)
register_game() { # register_game <game-id> <display-name> <fullscreen-cmd> <windowed-cmd> <windowed-guessed:0|1>
  local gid="$1" name="$2" fs="$3" win="$4" guessed="$5" line

  line="$gid|$name|$fs|$win"
  if game_exists "$gid"; then
    echo "  games.conf already has an entry for '$gid' — replacing it in place."
    replace_game_line "$gid" "$line" || return 1
  else
    if [[ "$guessed" == "1" ]]; then
      append_line "$GAMES_CONF" "# TODO: windowed command for $gid is a copy of the fullscreen command - verify the real windowed flag." || return 1
    fi
    append_line "$GAMES_CONF" "$line" || return 1
  fi
  echo "  games.conf <- $line"
}

register_controller() { # register_controller <vid:pid> <game-id> <desc>
  local id="$1" gid="$2" desc="$3" existing

  existing="$(mapping_for_vidpid "$id")"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$gid" ]]; then
      echo "  $id is already mapped -> $gid; nothing to change."
      return 0
    fi
    echo ""
    echo "  $id is ALREADY mapped -> $existing"
    if ! ask_yn "  Remap it to '$gid'? [y = Yes / n = leave unchanged]: "; then
      echo "  Left unchanged."
      return 0
    fi
    replace_controller_line "$id" "$id $gid   # $desc" || return 1
    echo "  controllers.conf (edited in place) <- $id $gid   # $desc"
    return 0
  fi

  append_line "$CONTROLLERS_CONF" "$id $gid   # $desc" || return 1
  echo "  controllers.conf <- $id $gid   # $desc"
}

write_phase() { # write_phase <gid> <name> <fs-cmd> <win-cmd> <guessed>
  local gid="$1" name="$2" fs="$3" win="$4" guessed="$5" i

  WRITE_FAILED_FILE=""
  if [[ "${INSTALL_NEW:-0}" != "1" ]]; then
    echo "  games.conf   : unchanged (mapping to existing entry '$gid')"
  elif ! register_game "$gid" "$name" "$fs" "$win" "$guessed"; then
    WRITE_FAILED_FILE="$GAMES_CONF"
    return 1
  fi
  for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
    if ! register_controller "${DEV_ID[$i]}" "$gid" "${DEV_DESC[$i]}"; then
      WRITE_FAILED_FILE="$CONTROLLERS_CONF"
      return 1
    fi
  done
}

# --- Post-write validation ------------------------------------------------------------
# WARNINGS ONLY -- the writes already succeeded. This catches the mistakes that would
# otherwise show up as a black screen at boot instead of as a message here.
validate_confs() {
  local warned=0
  local line c_id c_gid g_id g_fs first dups n_ctrl=0 n_game=0
  local -a ids=()

  echo "${C_H}--- Validation ---${C_0}"

  # 1. every controllers.conf mapping must point at a real games.conf entry
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    n_ctrl=$(( n_ctrl + 1 ))
    read -r c_id c_gid _ <<< "$line"
    if [[ ! "$c_id" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || [[ -z "$c_gid" || "$c_gid" == "#"* ]]; then
      echo "  ${C_W}WARNING:${C_0} controllers.conf line is not 'VID:PID GAME_ID': $line"
      warned=1
      continue
    fi
    ids+=("$c_id")
    if ! game_exists "$c_gid"; then
      echo "  ${C_W}WARNING:${C_0} controllers.conf maps $c_id to game id '$c_gid',"
      echo "           which has NO entry in $GAMES_CONF — that controller boots to nothing."
      warned=1
    fi
  done < <(conf_lines "$CONTROLLERS_CONF")

  # 2. duplicate VID:PID lines (0000:0000 is the documented 'not yet known' placeholder)
  if [[ ${#ids[@]} -gt 0 ]]; then
    dups="$(printf '%s\n' "${ids[@]}" | grep -v '^0000:0000$' | sort | uniq -d || true)"
    if [[ -n "$dups" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  ${C_W}WARNING:${C_0} $line appears on more than one controllers.conf line —"
        echo "           only the FIRST line is used. Delete the extras in"
        echo "           $CONTROLLERS_CONF"
        warned=1
      done <<< "$dups"
    fi
    if printf '%s\n' "${ids[@]}" | grep -q '^0000:0000$'; then
      echo "  NOTE: controllers.conf still has 0000:0000 placeholder line(s) — those never match."
    fi
  fi

  # 3. each game's FULLSCREEN command must start with something that actually runs.
  #    Commands may be sequences (e.g. `xrandr --rate 95; /path/game`), so EVERY
  #    segment's leading word is checked -- checking only the first word would let
  #    the xrandr prefix hide a missing game binary from this validation.
  #    command -v covers both an absolute path and a PATH name (e.g. dolphin-emu).
  local seg segs
  while IFS='|' read -r g_id _ g_fs _; do
    [[ -z "$g_id" ]] && continue
    n_game=$(( n_game + 1 ))
    if [[ -z "$g_fs" ]]; then
      echo "  ${C_W}WARNING:${C_0} games.conf entry '$g_id' has an EMPTY fullscreen command."
      warned=1
      continue
    fi
    segs="${g_fs//&&/;}"
    while IFS= read -r seg; do
      seg="$(trim "$seg")"
      [[ -z "$seg" ]] && continue
      read -r first _ <<< "$seg"
      if ! command -v "$first" >/dev/null 2>&1 && [[ ! -x "$first" ]]; then
        echo "  ${C_W}WARNING:${C_0} games.conf entry '$g_id' runs '$first', which does not exist or is"
        echo "           not executable on this machine. Fix the command in $GAMES_CONF"
        echo "           (or install the game), or that hotkey/boot match will fail silently."
        warned=1
      fi
    done <<< "${segs//;/$'\n'}"
  done < <(conf_lines "$GAMES_CONF")

  # 4. boot-order.conf vs games.conf: both directions
  local g found
  load_boot_order
  for g in ${B_GID[@]+"${B_GID[@]}"}; do
    [[ "$g" == "desktop" ]] && continue   # reserved boot-to-desktop entry
    if ! game_exists "$g"; then
      echo "  ${C_W}WARNING:${C_0} boot-order.conf lists '$g', which has no games.conf entry."
      warned=1
    fi
  done
  # During firstboot this check is noise: placement is deliberately deferred
  # to the boot-order step, which adds every game before the user is done.
  if [[ "${FIRSTBOOT_MODE:-0}" != "1" ]]; then
    while IFS='|' read -r g_id _; do
      g_id="$(trim "${g_id-}")"
      [[ -z "$g_id" ]] && continue
      found=0; for g in ${B_GID[@]+"${B_GID[@]}"}; do [[ "$g" == "$g_id" ]] && found=1 && break; done
      if [[ $found -eq 0 ]]; then
        echo "  ${C_W}WARNING:${C_0} game '$g_id' is not in $ORDER_CONF — it will sort LAST at boot."
        warned=1
      fi
    done < <(conf_lines "$GAMES_CONF")
  fi

  if [[ "$warned" -eq 0 ]]; then
    if [[ "$n_ctrl" -eq 0 ]]; then
      echo "  OK — $n_game game(s), no problems found."
    else
      echo "  OK — $n_ctrl controller line(s), $n_game game(s), no problems found."
    fi
  fi
  echo ""
}

# =====================================================================================
# Boot order (GAMES)  -- the single priority system. One GAME_ID per line in
# boot-order.conf, top boots first. Controllers carry no priority of their own.
# =====================================================================================
B_GID=()

load_boot_order() {
  B_GID=()
  local g _rest seen dup
  [[ -r "$ORDER_CONF" ]] || return 0
  while read -r g _rest; do
    g="${g%$'\r'}"
    [[ -z "$g" || "$g" == \#* ]] && continue
    dup=0; for seen in ${B_GID[@]+"${B_GID[@]}"}; do [[ "$seen" == "$g" ]] && dup=1 && break; done
    [[ $dup -eq 0 ]] && B_GID+=("$g")
  done < "$ORDER_CONF"
}

# Games registered in games.conf but missing from boot-order.conf join the end
# of the list (mirrors the boot-selector: an unlisted game sorts LAST).
augment_boot_order_with_games() {
  local id _r found g
  while IFS='|' read -r id _r; do
    id="$(trim "${id-}")"
    [[ -z "$id" ]] && continue
    found=0; for g in ${B_GID[@]+"${B_GID[@]}"}; do [[ "$g" == "$id" ]] && found=1 && break; done
    [[ $found -eq 0 ]] && B_GID+=("$id")
  done < <(conf_lines "$GAMES_CONF")
}

# MARKED: space-separated gid list; those rows get a leading '*' in the print.
MARKED=""
print_game_order() { # print_game_order <label> <gid...>
  local label=$1 n=0 g name star nctl
  shift
  echo "--- $label ---"
  for g in "$@"; do
    n=$(( n + 1 ))
    star=" "; [[ " $MARKED " == *" $g "* ]] && star="*"
    if [[ "$g" == "desktop" ]]; then
      # Reserved entry: boots to the bare desktop instead of a game. Putting it
      # on TOP makes the kiosk always boot to the desktop.
      printf " %s${C_N}%2d)${C_0} %-32s (%s)  -- boot to desktop, no game\n" "$star" "$n" "Desktop mode" "$g"
      continue
    fi
    name="$(game_display_name "$g")"; [[ -n "$name" ]] || name="$g"
    nctl="$(conf_lines "$CONTROLLERS_CONF" | awk -v g="$g" '$2==g {c++} END {print c+0}')"
    printf " %s${C_N}%2d)${C_0} %-32s (%s)  -- %s controller(s)\n" "$star" "$n" "$name" "$g" "$nctl"
  done
  echo ""
}

# write_boot_order <gid...> -- keeps the file's leading comment block, then the
# ids in the given order. Same tmp-beside-target + mv pattern as the rewriters.
write_boot_order() {
  local tmp="$ORDER_CONF.tmp.$$" g
  if ! {
      if [[ -r "$ORDER_CONF" ]]; then
        awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next } { exit }' "$ORDER_CONF"
      else
        echo "# Boot priority: one GAME_ID per line, TOP line boots first."
      fi
      for g in "$@"; do printf '%s\n' "$g"; done
    } | as_root tee "$tmp" >/dev/null; then
    write_fail "$ORDER_CONF" "writing the new boot order"
    as_root rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! as_root mv -f "$tmp" "$ORDER_CONF"; then
    write_fail "$ORDER_CONF" "replacing the file with the new order"
    return 1
  fi
}

# place_game_in_boot_order <gid> -- for a NEWLY installed game (Tyler's spec):
# preview it at the default spot (bottom), confirm, or pick a position. A game
# already in boot-order.conf keeps its spot silently.
place_game_in_boot_order() {
  local gid=$1 g pos total input n
  load_boot_order
  for g in ${B_GID[@]+"${B_GID[@]}"}; do
    [[ "$g" == "$gid" ]] && return 0
  done
  augment_boot_order_with_games          # pulls in $gid (register_game ran first)
  local -a others=()
  for g in ${B_GID[@]+"${B_GID[@]}"}; do [[ "$g" == "$gid" ]] || others+=("$g"); done
  total=$(( ${#others[@]} + 1 ))
  # Default: bottom of the GAMES -- above a trailing "desktop" entry, so a new
  # game still auto-boots by default instead of hiding below Desktop mode.
  pos=$total
  if [[ ${#others[@]} -gt 0 && "${others[$(( ${#others[@]} - 1 ))]}" == "desktop" ]]; then
    pos=$(( total - 1 ))
  fi
  while true; do
    local -a order=()
    n=0
    for g in ${others[@]+"${others[@]}"}; do
      n=$(( n + 1 ))
      (( n == pos )) && order+=("$gid")
      order+=("$g")
    done
    (( ${#order[@]} < total )) && order+=("$gid")

    echo ""
    MARKED="$gid"
    print_game_order "Boot order with the new game placed (nothing final yet)" "${order[@]}"
    MARKED=""
    echo "  * = the game being placed"
    echo ""
    if ask_yn "  Place it here? [y = Yes / n = pick a position]: "; then
      write_boot_order "${order[@]}" || return 1
      return 0
    fi
    while true; do
      echo -n "  Position for '$gid' (1 = boots first) [1-$total]: "
      read -r input || input=""
      input="$(trim "$input")"
      if [[ "$input" =~ ^[0-9]+$ ]] && (( 10#$input >= 1 && 10#$input <= total )); then
        pos=$(( 10#$input ))
        break
      fi
      echo "  Enter a number from 1 to $total."
    done
  done
}

reorder_flow() {
  local input i idx g
  while true; do
    load_boot_order
    augment_boot_order_with_games
    if [[ ${#B_GID[@]} -eq 0 ]]; then
      echo "No games are configured yet -- nothing to reorder."
      echo "(Install a game first, then come back here.)"
      return 0
    fi

    print_game_order "Boot order (current, top boots first)" "${B_GID[@]}"
    echo "New order: comma-separated numbers, highest priority first."
    echo "A PARTIAL list moves those games to the top; the rest keep their order."
    echo -n "New order (Enter = keep current, 'q' = quit): "
    read -r input || return 0
    input="$(trim "$input")"
    case "$(lower "$input")" in
      "")          echo "Keeping the current order."; return 0 ;;
      q|quit|exit) return 0 ;;
    esac

    local -a sel=() picked=() rest=() neworder=()
    local ok=1 d dup found
    IFS=',' read -ra sel <<< "$input"
    for i in ${sel[@]+"${sel[@]}"}; do
      i="$(printf '%s' "$i" | tr -d '[:space:]')"
      [[ -z "$i" ]] && continue
      if [[ ! "$i" =~ ^[0-9]+$ ]] || (( 10#$i < 1 || 10#$i > ${#B_GID[@]} )); then
        echo "  Invalid entry: '$i'. Use numbers 1-${#B_GID[@]} from the list above."
        ok=0; break
      fi
      idx=$(( 10#$i - 1 ))
      dup=0; for d in ${picked[@]+"${picked[@]}"}; do [[ "$d" == "$idx" ]] && dup=1 && break; done
      [[ $dup -eq 0 ]] && picked+=("$idx")
    done
    [[ $ok -eq 1 ]] || { echo ""; continue; }
    [[ ${#picked[@]} -gt 0 ]] || { echo "  Nothing selected."; echo ""; continue; }

    for i in "${!B_GID[@]}"; do
      found=0; for d in "${picked[@]}"; do [[ "$d" == "$i" ]] && found=1 && break; done
      [[ $found -eq 0 ]] && rest+=("$i")
    done
    MARKED=""
    for i in "${picked[@]}"; do neworder+=("${B_GID[$i]}"); MARKED+="${B_GID[$i]} "; done
    for i in ${rest[@]+"${rest[@]}"}; do neworder+=("${B_GID[$i]}"); done

    echo ""
    print_game_order "PREVIEW: new boot order (nothing written yet)" "${neworder[@]}"
    MARKED=""
    echo "  * = the games you moved"
    echo ""
    if ask_yn "Apply this order? [y = Yes / n = No, start over]: "; then
      write_boot_order "${neworder[@]}" || return 1
      echo ""
      load_boot_order
      print_game_order "Boot order (as now saved)" "${B_GID[@]}"
      validate_confs
      return 0
    fi
    echo ""
    echo "Starting over..."
    echo ""
  done
}

# =====================================================================================
# Main flow  (Function 1 -> Function 2 -> confirm; N restarts at Function 1)
# =====================================================================================
WRITE_FAILED_FILE=""

# =====================================================================================
# Standalone game install (no controller mapping) -- also the first step of the
# firstboot guided setup. Reuses intake/install/placement wholesale.
# =====================================================================================
install_game_flow() {
  local gid name default_name fs_cmd win_cmd guessed
  while true; do
    INSTALL_NEW=1
    INSTALLER_PATH=""
    SELECTED=()                      # no controllers in this mode
    if ! intake_installer; then
      echo "Install cancelled."
      return 0
    fi
    while true; do
      echo -n "Short game id for the new game (lowercase, no spaces): "
      read -r gid || gid=""
      gid="$(lower "$(trim "$gid")")"
      if [[ "$gid" == "desktop" ]]; then
        echo "  'desktop' is reserved (the boot-to-desktop entry). Pick another id."
        continue
      fi
      if [[ "$gid" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then break; fi
      echo "  Invalid id. Use lowercase letters, digits, '-' or '_' only."
    done
    game_exists "$gid" && echo "  NOTE: '$gid' already exists -- this UPDATES its entry (its boot-order spot is kept)."
    default_name="$gid"
    game_exists "$gid" && default_name="$(game_display_name "$gid")"
    echo -n "Display name (shown in the Openbox menu) [$default_name]: "
    read -r name || name=""
    name="$(trim "$name")"
    [[ -z "$name" ]] && name="$default_name"
    name="${name//|/ }"

    echo ""
    echo "${C_H}--- Confirm ---${C_0}"
    echo "  New game     : $name ($gid)"
    echo "  Installer    : $INSTALLER_PATH"
    echo "  Install dir  : $GAMES_DIR/$gid/"
    echo ""
    if ! ask_yn "Proceed? [y = Yes / n = No, start over]: "; then
      echo ""
      echo "Starting over..."
      echo ""
      continue
    fi

    echo ""
    if ! install_package "$INSTALLER_PATH" "$gid"; then
      echo ""
      echo "ERROR: install of '$INSTALLER_PATH' FAILED — no configuration was written."
      echo "       Inspect: $GAMES_DIR/$gid/"
      return 1
    fi
    fs_cmd="$(pick_launch_binary "$gid")"
    echo ""
    echo -n "Windowed launch command (Enter = same as fullscreen): "
    read -r win_cmd || win_cmd=""
    win_cmd="$(trim "$win_cmd")"
    guessed=0
    if [[ -z "$win_cmd" ]]; then
      win_cmd="$fs_cmd"
      guessed=1
    fi
    fs_cmd="${fs_cmd//|/ }"
    win_cmd="${win_cmd//|/ }"
    echo "${C_H}--- Writing configuration ---${C_0}"
    if ! write_phase "$gid" "$name" "$fs_cmd" "$win_cmd" "$guessed"; then
      echo "  Write FAILED ($WRITE_FAILED_FILE) — inspect the confs by hand and re-run."
      return 1
    fi
    if [[ "$FIRSTBOOT_MODE" != "1" ]]; then
      place_game_in_boot_order "$gid" || return 1
    fi
    echo ""
    validate_confs
    if ! ask_yn "Install another game? [y = Yes / n = No]: "; then
      return 0
    fi
    echo ""
  done
}

# set_desktop_first on|off -- move the reserved 'desktop' entry to the top
# (always boot to desktop) or the bottom (games auto-boot) of the boot order.
set_desktop_first() {
  local mode=$1 g
  load_boot_order
  augment_boot_order_with_games
  local -a rest=()
  for g in ${B_GID[@]+"${B_GID[@]}"}; do [[ "$g" == "desktop" ]] || rest+=("$g"); done
  if [[ "$mode" == "on" ]]; then
    write_boot_order desktop ${rest[@]+"${rest[@]}"}
  else
    write_boot_order ${rest[@]+"${rest[@]}"} desktop
  fi
}

# =====================================================================================
# Firstboot: one-time guided setup on a fresh system (Tyler's spec: install a
# game FIRST, then assign controllers, then choose the boot behaviour; every
# step skippable; if everything is skipped, explain how to do it later).
# STATELESS (Tyler's rule): no run-once marker. Setup offers itself at every
# boot for as long as the kiosk is completely unconfigured -- an unconfigured
# kiosk is useless, so asking is the point. Configuring EITHER a game or a
# controller stops it (games-only, menu-driven setups are legitimate).
# =====================================================================================
firstboot_needed() {
  local g c
  g="$(conf_lines "$GAMES_CONF" | grep -c . || true)"
  c="$(conf_lines "$CONTROLLERS_CONF" | grep -c . || true)"
  [[ "$g" -eq 0 && "$c" -eq 0 ]]
}

firstboot_flow() {
  FIRSTBOOT_MODE=1
  banner
  echo "Welcome! This looks like a fresh rhythm-kiosk: no games are installed yet,"
  echo "or no controllers are assigned. This one-time setup walks through both;"
  echo "every step can be skipped and done later from the right-click menu."
  echo ""
  local did=0
  if ask_yn "Step 1/3 — Install your first game now? [y = Yes / n = skip]: "; then
    ( install_game_flow )
    did=1
  fi
  echo ""
  if [[ "$(conf_lines "$GAMES_CONF" | grep -c . || true)" -gt 0 ]]; then
    if ask_yn "Step 2/3 — Assign plugged-in controllers to games now? [y = Yes / n = skip]: "; then
      ( map_flow )
      did=1
    fi
  else
    echo "Step 2/3 — skipped automatically: no games are installed to assign controllers to."
  fi
  echo ""
  if [[ "$(conf_lines "$GAMES_CONF" | grep -c . || true)" -gt 0 ]]; then
    echo "Step 3/3 — Boot order."
    # The games installed in step 1 join the boot order here (placement was
    # deliberately deferred so all games and controllers went in first).
    # Games first, desktop last; the auto-start question decides desktop's spot.
    load_boot_order
    augment_boot_order_with_games
    local -a fb_games=()
    local fb_g
    for fb_g in ${B_GID[@]+"${B_GID[@]}"}; do
      [[ "$fb_g" == "desktop" ]] || fb_games+=("$fb_g")
    done
    write_boot_order ${fb_games[@]+"${fb_games[@]}"} desktop || true
    load_boot_order
    print_game_order "Boot order (top boots first)" "${B_GID[@]}"
    if ask_yn "Adjust this order? [y = Yes / n = keep it]: "; then
      reorder_flow
    fi
    echo ""
    echo "On future boots, a plugged-in controller can auto-start its game"
    echo "(highest in the boot order wins), or the kiosk can always boot to this"
    echo "desktop first (games then start from the right-click menu)."
    if ask_yn "Auto-start games on boot? [y = auto-start / n = always desktop first]: "; then
      set_desktop_first off
    else
      set_desktop_first on
    fi
    did=1
  fi
  echo ""
  if [[ $did -eq 0 ]]; then
    cat <<'MSG'
No problem — everything can be set up later:
  * Right-click the desktop (or press Super+M / the Menu key) and open
    the "Mapping Editor".
  * "Install a new game" installs games (browse for the installer file).
  * "Map controller(s) to a game" assigns plugged-in controllers.
  * "Reorder boot priorities" decides which game wins at boot — moving
    "Desktop mode" to the top makes the kiosk always boot to this desktop.
MSG
  fi
  echo ""
  if firstboot_needed; then
    echo "No configuration saved. Setup will rerun on reboot unless game or"
    echo "controller is configured."
  else
    echo "First-time setup finished."
    echo ""
    if ask_yn "Reboot now? [y = reboot / n = stay in desktop mode]: "; then
      echo "Rebooting..."
      sudo -n systemctl reboot || echo "  ${C_W}Reboot failed${C_0} -- check /etc/sudoers.d/010_kiosk-nopasswd, or reboot from the menu."
    else
      echo "Staying in desktop mode."
    fi
  fi
}

# =====================================================================================
# Uninstall a game: removes its games.conf entry, every controller mapping to
# it, its boot-order line, and its payload directory -- the four places a game
# lives. Config lines are removed by streaming rewrites that keep comments.
# =====================================================================================
remove_conf_lines() { # remove_conf_lines <file> <awk-condition-for-KEEPING>
  local file=$1 cond=$2 tmp="$1.tmp.$$"
  if ! awk "$cond { print }" "$file" | as_root tee "$tmp" >/dev/null; then
    write_fail "$file" "removing the game's lines"
    as_root rm -f "$tmp" 2>/dev/null
    return 1
  fi
  as_root mv -f "$tmp" "$file" || { write_fail "$file" "replacing the file"; return 1; }
}

uninstall_flow() {
  local -a ids=() names=()
  local line id name sel gid gname nctl fs first payload input
  while IFS= read -r line; do
    IFS='|' read -r id name _ <<<"$line"
    id="$(trim "${id-}")"; [[ -n "$id" ]] || continue
    name="$(trim "${name-}")"; [[ -n "$name" ]] || name="$id"
    ids+=("$id"); names+=("$name")
  done < <(conf_lines "$GAMES_CONF")

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No games are configured -- nothing to uninstall."
    return 0
  fi

  echo "${C_H}--- Uninstall a game ---${C_0}"
  local i
  for i in "${!ids[@]}"; do
    nctl="$(conf_lines "$CONTROLLERS_CONF" | awk -v g="${ids[$i]}" '$2==g {c++} END {print c+0}')"
    printf "  ${C_N}%2d)${C_0} %s (%s)  -- %s controller(s) mapped\n" "$(( i + 1 ))" "${names[$i]}" "${ids[$i]}" "$nctl"
  done
  echo ""
  while true; do
    echo -n "Uninstall which game? [number or game id, 'q' = cancel]: "
    read -r sel || return 0
    sel="$(lower "$(trim "$sel")")"
    case "$sel" in
      q|quit|exit) return 0 ;;
      "")          echo "  Blank entry -- pick from the list, or 'q'."; continue ;;
    esac
    gid=""
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#ids[@]} )); then
      gid="${ids[$(( 10#$sel - 1 ))]}"
    else
      for i in "${!ids[@]}"; do [[ "${ids[$i]}" == "$sel" ]] && gid="$sel" && break; done
    fi
    [[ -n "$gid" ]] && break
    echo "  '$sel' is not in the list."
  done

  gname="$(game_display_name "$gid")"; [[ -n "$gname" ]] || gname="$gid"
  nctl="$(conf_lines "$CONTROLLERS_CONF" | awk -v g="$gid" '$2==g {c++} END {print c+0}')"
  fs="$(conf_lines "$GAMES_CONF" | awk -F'|' -v g="$gid" '$1==g {print $3; exit}')"
  read -r first _ <<< "$fs"
  payload="$GAMES_DIR/$gid"

  echo ""
  echo "${C_H}--- Confirm uninstall ---${C_0}"
  echo "  Game         : $gname ($gid)"
  if [[ -d "$payload" ]]; then
    echo "  Payload      : $payload ($(du -sh "$payload" 2>/dev/null | awk '{print $1}')) -- will be DELETED"
  else
    echo "  Payload      : (no directory under $GAMES_DIR)"
  fi
  echo "  Also removed : its games.conf entry, $nctl controller mapping(s), its boot-order line"
  if [[ -n "$first" && "$first" != "$GAMES_DIR"/* && "$first" != xrandr ]]; then
    echo "  NOTE         : the launch command uses '$first', which lives outside"
    echo "                 $GAMES_DIR -- if it came from a system package"
    echo "                 (e.g. dolphin-emu), remove that separately: sudo apt remove <package>"
  fi
  echo ""
  if ! ask_yn "Uninstall '$gname'? [y = Yes / n = Cancel]: "; then
    echo "  Cancelled."
    return 0
  fi

  echo "${C_H}--- Removing ---${C_0}"
  remove_conf_lines "$CONTROLLERS_CONF" "\$2 != \"$gid\"" || return 1
  echo "  controllers.conf : $nctl mapping(s) removed"
  local tmp="$GAMES_CONF.tmp.$$"
  if ! awk -F'|' -v g="$gid" '$1 != g { print }' "$GAMES_CONF" | as_root tee "$tmp" >/dev/null; then
    write_fail "$GAMES_CONF" "removing the game's entry"
    as_root rm -f "$tmp" 2>/dev/null
    return 1
  fi
  as_root mv -f "$tmp" "$GAMES_CONF" || { write_fail "$GAMES_CONF" "replacing the file"; return 1; }
  echo "  games.conf       : entry removed"
  remove_conf_lines "$ORDER_CONF" "\$1 != \"$gid\"" || return 1
  echo "  boot-order.conf  : line removed"
  if [[ -d "$payload" ]]; then
    if as_root rm -rf -- "$payload"; then
      echo "  $payload : deleted"
    else
      echo "  ${C_W}WARNING:${C_0} could not delete $payload -- remove it by hand."
    fi
  fi
  echo ""
  validate_confs
}

banner() {
  clear 2>/dev/null || true
  echo "====================================================================="
  echo " ${C_H}Rhythm Kiosk — Controller / Game Mapping Editor${C_0}"
  echo " root: $ROOT"
  [[ -n "${RHYTHM_FAKE_LSUSB:-}" ]] && echo " *** DRY RUN: device list faked from $RHYTHM_FAKE_LSUSB ***"
  echo "====================================================================="
  echo ""
}

map_flow() {
  while true; do
    banner

    # ---------- FUNCTION 1 ----------
    enumerate_devices || { echo "Could not enumerate USB devices."; exit 1; }
    print_device_list
    if [[ ${#DEV_ID[@]} -eq 0 ]]; then
      echo "Plug in the controller you want to map, then re-run this editor."
      exit 1
    fi
    if ! select_devices; then
      echo "No devices selected. Exiting."
      exit 1
    fi

    echo ""
    echo "${C_H}--- Selected Controller(s) ---${C_0}"
    local i
    for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
      printf '  %s  %s' "${DEV_ID[$i]}" "${DEV_DESC[$i]}"
      [[ "${DEV_STATE[$i]}" == "mapped" ]] && printf '   (currently mapped -> %s)' "${DEV_GAME[$i]}"
      printf '\n'
    done
    echo ""

    # ---------- FUNCTION 2: which game? ----------
    # Backing out of a sub-step returns HERE: only 'q' at this game list leaves
    # the section (Tyler's rule). "Install a NEW game" runs the standard
    # install flow, then comes back so the new game can be assigned.
    local gid name choice
    INSTALL_NEW=0
    INSTALLER_PATH=""
    while true; do
      if ! choice="$(choose_game)"; then
        echo "Aborted."
        exit 0
      fi
      [[ "$choice" != "NEW" ]] && break
      echo ""
      ( install_game_flow )
      echo ""
    done
    gid="$choice"
    name="$(game_display_name "$gid")"
    [[ -n "$name" ]] || name="$gid"

    # ---------- Confirm ----------
    echo ""
    echo "${C_H}--- Confirm ---${C_0}"
    echo "  Game         : $name ($gid)"
    echo "  Controllers  :"
    for i in ${SELECTED[@]+"${SELECTED[@]}"}; do
      printf '    %s  %s\n' "${DEV_ID[$i]}" "${DEV_DESC[$i]}"
    done
    echo ""
    if ! ask_yn "Proceed? [y = Yes / n = No, start over]: "; then
      echo ""
      echo "Starting over..."
      pause_enter
      continue
    fi

    # ---------- Do it ----------
    # Installing happens in install_game_flow only; here we always map to an
    # existing game, so only controllers.conf is written.
    echo ""
    local fs_cmd="" win_cmd="" guessed=0

    echo "${C_H}--- Writing configuration ---${C_0}"
    if ! write_phase "$gid" "$name" "$fs_cmd" "$win_cmd" "$guessed"; then
      echo ""
      echo "====================================================================="
      echo " ABORTED: configuration write failed — POSSIBLE PARTIAL STATE"
      echo "====================================================================="
      echo "  The write phase stopped at the FIRST failure, so nothing after it was"
      echo "  attempted — but writes made BEFORE it are already on disk."
      echo ""
      echo "  Failed while writing : $WRITE_FAILED_FILE"
      echo ""
      echo "  Inspect these by hand, in this order:"
      echo "    $GAMES_CONF          <- the '$gid|...' entry (written first)"
      echo "    $CONTROLLERS_CONF    <- one 'VID:PID $gid' line per controller"
      echo "    $ORDER_CONF          <- the boot order (one game id per line)"
      echo "    $GAMES_DIR/$gid/   <- the installed payload (left in place)"
      echo "    ${CONTROLLERS_CONF}.tmp.* / ${GAMES_CONF}.tmp.*   <- leftover temp files, if any"
      echo ""
      echo "  A controllers.conf line pointing at a games.conf entry that is missing"
      echo "  boots that controller to nothing. Fix the pair, then re-run this editor."
      exit 1
    fi

    echo ""
    validate_confs

    echo "${C_H}--- Done ---${C_0}"
    load_boot_order
    augment_boot_order_with_games
    print_game_order "Boot order now" ${B_GID[@]+"${B_GID[@]}"}
    echo "  Controller mappings:"
    conf_lines "$CONTROLLERS_CONF" | sed 's/^/    /'
    echo ""
    echo "  Reboot (or replug + reboot) to test boot-time selection."
    echo ""
    if ! ask_yn "Map another controller/game? [y = Yes / n = No]: "; then break; fi
  done
}

main() {
  # Quiet gate for the Openbox autostart: exit 0 = firstboot should run.
  # Deliberately BEFORE the sudo pre-flight -- it must never prompt or print.
  if [[ "${1:-}" == "--firstboot-check" ]]; then
    trap - EXIT          # headless gate: no close-window pause, ever
    firstboot_needed
    exit $?
  fi

  # Nothing -- not even mkdir -- happens before sudo is known to be usable.
  preflight_sudo
  ensure_files || exit 1

  case "${1:-}" in
    --reorder)
      banner
      reorder_flow
      echo "Exiting mapping editor."
      return 0
      ;;
    --install-game)
      banner
      install_game_flow
      echo "Exiting mapping editor."
      return 0
      ;;
    --firstboot)
      firstboot_flow
      pause_enter
      return 0
      ;;
  esac

  local choice
  while true; do
    banner
    echo "  ${C_N}1)${C_0} Map controller(s) to a game"
    echo "  ${C_N}2)${C_0} Install a new game"
    echo "  ${C_N}3)${C_0} Reorder boot priorities"
    echo "  ${C_N}4)${C_0} Uninstall a game"
    echo "  ${C_N}q)${C_0} Quit"
    echo ""
    echo -n "Choose [1/2/3/4/q]: "
    read -r choice || choice="q"
    case "$(lower "$(trim "$choice")")" in
      1) map_flow ;;
      2) banner; install_game_flow; pause_enter ;;
      3) banner; reorder_flow; pause_enter ;;
      4) banner; uninstall_flow; pause_enter ;;
      q|quit|exit) break ;;
      "") echo "  Blank entry -- choose 1, 2, 3, 4 or q." ; sleep 1 ;;
      *) echo "  Invalid choice: $choice" ; sleep 1 ;;
    esac
  done

  echo "Exiting mapping editor."
}

main "$@"
