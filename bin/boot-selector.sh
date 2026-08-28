#!/usr/bin/env bash
# rhythm-kiosk :: install to /opt/rhythm-kiosk/bin/boot-selector.sh  (chmod 755)
#
# One-shot boot selector. Enumerates USB once, matches it against
# controllers.conf, and launches the matched game with the LOWEST priority
# number. No polling, no udev, no kb/mouse detection.
#
# ERROR POLICY (project contract). There is exactly ONE silent outcome:
# a readable conf holding usable mappings matched nothing -> exit 0 and the
# bare Openbox desktop remains (= maintenance mode). That is the intended
# fallback for "no controller plugged in" and must stay quiet.
# Every other way this can fail to boot a game is LOUD: it raises a
# kiosk-alert naming the exact file to open. Those paths still exit 0, so the
# Openbox session survives and the user lands in maintenance mode WITH the
# error on screen -- visibility comes from the alert, not the exit status.
#
# Dry-run on another machine:
#   RHYTHM_KIOSK_ROOT=/path/to/tree \
#   RHYTHM_KIOSK_STATE_DIR=/tmp/state \
#   RHYTHM_FAKE_LSUSB=/path/to/fake-lsusb.txt ./boot-selector.sh
# where the fixture file holds lines in `lsusb` format, e.g.
#   Bus 001 Device 004: ID 1430:4748 RedOctane Guitar Hero X-plorer

# No -e: a no-match `grep` returning 1 is an expected, non-fatal outcome here.
set -uo pipefail

ROOT="${RHYTHM_KIOSK_ROOT:-/opt/rhythm-kiosk}"
CONF="$ROOT/controllers.conf"
LAUNCH="$ROOT/bin/rhythm-launch"
ALERT="$ROOT/bin/kiosk-alert"

PROG=${0##*/}

# alert <TITLE> <BODY> -- hand off to the shared helper (logs + on-screen
# dialog). If the helper itself is missing the install is broken, so fall back
# to syslog + stderr rather than losing the message entirely.
alert() {
	if [[ -x "$ALERT" ]]; then
		"$ALERT" "$1" "$2"
	else
		logger -t "$PROG" -p user.err -- "$1: $2" 2>/dev/null || true
		printf '%s: %s\n%s\n' "$PROG" "$1" "$2" >&2
		printf '%s: (the alert helper %s is also missing or not executable)\n' \
			"$PROG" "$ALERT" >&2
	fi
	return 0
}

# ------------------------------------------------------------ controllers.conf

if [[ ! -e "$CONF" ]]; then
	alert "No controller mapping file" \
"boot-selector.sh cannot find the controller-to-game mapping file:

    $CONF

The system will only boot into desktop mode until controllers.conf is
present at boot with valid entries.

Fix: Locate/create controllers.conf and save it to $ROOT/ or run
$ROOT/bin/mapping-editor.sh to automatically add and validate your
controllers."
	exit 0
fi

if [[ ! -r "$CONF" ]]; then
	alert "Controller mapping file is not readable" \
"boot-selector.sh found the mapping file but cannot read it:

    $CONF

That is a permissions problem, not a controller problem.

Fix: sudo chmod 644 $CONF  (and check it is owned root:root)."
	exit 0
fi

# ------------------------------------------------------------------- lsusb

if [[ -n "${RHYTHM_FAKE_LSUSB:-}" ]]; then
	# Dry-run path only; a broken fixture is a test-setup error, but say so.
	if ! usb=$(cat -- "$RHYTHM_FAKE_LSUSB" 2>/dev/null); then
		alert "Fake lsusb fixture unreadable" \
"RHYTHM_FAKE_LSUSB is set but the fixture cannot be read:

    ${RHYTHM_FAKE_LSUSB}

Unset RHYTHM_FAKE_LSUSB to use real USB enumeration."
		exit 0
	fi
elif ! command -v lsusb >/dev/null 2>&1; then
	alert "lsusb is missing" \
"boot-selector.sh needs lsusb to see which controller is plugged in, and
lsusb is not installed on this machine. No controller can be detected.

Fix: sudo apt install usbutils

(The mapping file itself, $CONF, is fine.)"
	exit 0
else
	# stderr is folded in so a failure message is usable in the alert; stray
	# lsusb warnings on a success cannot match an "ID vvvv:pppp" line.
	if ! usb=$(lsusb 2>&1); then
		alert "lsusb failed" \
"boot-selector.sh ran lsusb to see which controller is plugged in and it
failed. No controller can be detected this boot.

lsusb said:
$usb

Fix: check USB is alive (dmesg | tail), then reboot. The mapping file
$CONF was read fine."
		exit 0
	fi
	if [[ -z "${usb//[[:space:]]/}" ]]; then
		alert "lsusb listed no USB devices at all" \
"lsusb ran but printed nothing -- not even the root hubs. USB is very
likely dead on this machine, so no controller can ever match.

Fix: check dmesg for USB errors and reboot. The mapping file
$CONF was read fine."
		exit 0
	fi
fi

# --------------------------------------------------------- match the mapping
# controllers.conf lines are  VID:PID GAME_ID  -- membership only, no priority.
# WHICH matched game wins is decided by boot-order.conf (top line boots first).

ORDER_CONF="$ROOT/boot-order.conf"

declare -A matched=()      # game ids whose controller is plugged in
valid=0                    # lines that parse as a mapping (placeholders included)
malformed=0                # non-blank, non-comment lines that do NOT parse
bad_lines=""               # "<lineno>: <text>" for each malformed line
lineno=0

while read -r vidpid game _rest; do
	lineno=$(( lineno + 1 ))
	# tolerate CRLF confs (edited on Windows): \r rides on the last token read
	vidpid=${vidpid%$'\r'}; game=${game%$'\r'}
	[[ -z "$vidpid" || "$vidpid" == \#* ]] && continue

	if [[ ! "$vidpid" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] \
		|| [[ -z "$game" || "$game" == \#* ]]; then
		malformed=$(( malformed + 1 ))
		bad_lines+="    line $lineno: $vidpid $game"$'\n'
		continue
	fi

	valid=$(( valid + 1 ))
	[[ "$vidpid" == "0000:0000" ]] && continue    # unfilled UNKNOWN placeholder
	grep -qiF -- "ID $vidpid" <<<"$usb" || continue
	matched["$game"]=1
done < "$CONF"

if (( valid == 0 )); then
	if (( malformed > 0 )); then
		alert "Controller mapping file is mangled" \
"Every mapping line in

    $CONF

is unreadable, so no controller can ever match. The file has probably been
corrupted or saved in the wrong format.

Expected on each line:  VID:PID  GAME_ID
for example:            1430:4748  clonehero

Lines that did not parse:
${bad_lines%$'\n'}

Fix: edit $CONF, or rebuild it with $ROOT/bin/mapping-editor.sh."
	else
		# A comments-only conf is EXPECTED before first-boot setup has run --
		# that is the exact state the firstboot walkthrough exists to fix, so
		# stay quiet while it is still pending (Tyler's rule).
		if [[ -x "$ROOT/bin/mapping-editor.sh" ]] \
			&& "$ROOT/bin/mapping-editor.sh" --firstboot-check </dev/null >/dev/null 2>&1; then
			exit 0
		fi
		alert "Controller mapping file has no mappings" \
"This file exists but contains only comments and blank lines:

    $CONF

With no mapping lines, no controller can ever launch a game and every boot
lands on this maintenance desktop.

Fix: add lines of the form  VID:PID  GAME_ID  (for example
1430:4748  clonehero), or right-click and select Mapping Editor to complete setup."
	fi
	exit 0
fi

if (( ${#matched[@]} == 0 )); then
	# Nothing matched. Normally that is the INTENDED fallback (no controller
	# plugged in) and must stay silent -- but if some lines were unreadable,
	# the plugged-in controller may have been dropped by a typo, so say so.
	if (( malformed > 0 )); then
		alert "Unreadable lines in the controller mapping file" \
"No plugged-in controller matched a mapping, and $malformed line(s) in

    $CONF

could not be read -- so a controller that IS plugged in may have been
skipped because of a typo.

Expected on each line:  VID:PID  GAME_ID

Lines that did not parse:
${bad_lines%$'\n'}

Fix: correct those lines, or rebuild the file with
$ROOT/bin/mapping-editor.sh. (If nothing is plugged in, this desktop is the
expected result and you can ignore this.)"
	fi
	exit 0
fi

# ------------------------------------------------ pick the game by boot order

best_game=""

if [[ -r "$ORDER_CONF" ]]; then
	while read -r g _rest; do
		g=${g%$'\r'}
		[[ -z "$g" || "$g" == \#* ]] && continue
		# Reserved entry: reaching 'desktop' before any matched game means the
		# user chose to boot to the desktop every time -- silent, by design.
		[[ "$g" == "desktop" ]] && exit 0
		if [[ -n "${matched[$g]:-}" ]]; then
			best_game="$g"
			break
		fi
	done < "$ORDER_CONF"
else
	alert "Boot order file is missing" \
"A controller matched, but the file that decides which game wins is gone:

    $ORDER_CONF

Falling back to the order games appear in $ROOT/games.conf for this boot.

Fix: restore boot-order.conf (one GAME_ID per line, top boots first), or run
$ROOT/bin/mapping-editor.sh -- it recreates the file."
fi

if [[ -z "$best_game" ]]; then
	# Matched game(s) not listed in boot-order.conf (or the file is missing):
	# fall back to games.conf order so the kiosk still boots something.
	while IFS='|' read -r gid _r; do
		gid=${gid%$'\r'}
		gid="${gid#"${gid%%[![:space:]]*}"}"; gid="${gid%"${gid##*[![:space:]]}"}"
		[[ -z "$gid" || "$gid" == \#* ]] && continue
		if [[ -n "${matched[$gid]:-}" ]]; then
			best_game="$gid"
			break
		fi
	done < "$ROOT/games.conf"
fi

if [[ -z "$best_game" ]]; then
	# Controllers matched, but their game id exists in neither boot-order.conf
	# nor games.conf -- rhythm-launch could never start it anyway.
	first_matched="$(printf '%s\n' "${!matched[@]}" | head -1)"
	alert "Matched controller's game is not configured" \
"A plugged-in controller is mapped to game id '$first_matched', but that id
has no entry in:

    $ROOT/games.conf

so there is nothing to launch. Fix the mapping in $CONF, or add the game
(run $ROOT/bin/mapping-editor.sh)."
	exit 0
fi

# --------------------------------------------------------------- hand off

if [[ ! -e "$LAUNCH" ]]; then
	alert "Game launcher is missing" \
"A controller matched and '$best_game' should be starting now, but the
launcher it needs does not exist:

    $LAUNCH

Fix: reinstall rhythm-launch from the rhythm-kiosk project tree into
$ROOT/bin/ (mode 0755)."
	exit 0
fi

if [[ ! -x "$LAUNCH" ]]; then
	alert "Game launcher is not executable" \
"A controller matched and '$best_game' should be starting now, but the
launcher cannot be run:

    $LAUNCH

Fix: sudo chmod 755 $LAUNCH"
	exit 0
fi

# Without execfail a non-interactive bash EXITS on a failed exec, which would
# make the alert below dead code and the failure silent -- the one thing this
# script must never be. With it, a failed exec returns and we can report it.
shopt -s execfail
exec "$LAUNCH" "$best_game"

# Only reached if exec itself failed (bad interpreter line, unreadable file...).
alert "Game launcher would not start" \
"A controller matched '$best_game', but the system refused to execute:

    $LAUNCH

That usually means a broken '#!' first line in that file, or a filesystem
mounted noexec.

Fix: check the first line of $LAUNCH, then run it by hand:
    $LAUNCH $best_game"
exit 0
