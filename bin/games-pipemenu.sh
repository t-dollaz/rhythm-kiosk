#!/usr/bin/env bash
# Install destination: /opt/rhythm-kiosk/bin/games-pipemenu.sh   (mode 0755)
#
# Openbox PIPE MENU generator for the "Games" submenu of the maintenance-mode
# root menu. Openbox runs this script every time the submenu is opened and
# parses its stdout, so games.conf is the single source of truth -- adding a
# game is one config line, never a menu edit.
#
# Wired up from menu.xml as:
#   <menu id="rhythm-games" label="Games"
#         execute="/opt/rhythm-kiosk/bin/games-pipemenu.sh"/>
#
# Menu launches are deliberately WINDOWED: the menu is only reachable in
# maintenance mode, where the point is to edit a game's settings with mouse and
# keyboard on the desktop. Fullscreen launches come from the boot selector and
# the hotkeys.

set -euo pipefail

KIOSK_ROOT=${RHYTHM_KIOSK_ROOT:-/opt/rhythm-kiosk}
GAMES_CONF=${RHYTHM_GAMES_CONF:-$KIOSK_ROOT/games.conf}
LAUNCH=${RHYTHM_LAUNCH:-$KIOSK_ROOT/bin/rhythm-launch}

trim() {
	local s=$1
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# Escape text for use inside XML element content and attribute values.
xml_escape() {
	local s=$1
	# The replacements are QUOTED on purpose: an unquoted "&" in a bash
	# pattern replacement means "the text that matched" (bash 5.2 patsub),
	# which silently mangles every entity.
	s=${s//&/"&amp;"}
	s=${s//</"&lt;"}
	s=${s//>/"&gt;"}
	s=${s//\"/"&quot;"}
	s=${s//\'/"&apos;"}
	printf '%s' "$s"
}

item() {  # item <label> <command>
	printf '  <item label="%s">\n' "$(xml_escape "$1")"
	printf '    <action name="Execute"><command>%s</command></action>\n' "$(xml_escape "$2")"
	printf '  </item>\n'
}

note() {  # a non-clickable-ish informational entry
	printf '  <item label="%s"><action name="Execute"><command>/bin/true</command></action></item>\n' \
		"$(xml_escape "$1")"
}

printf '<?xml version="1.0" encoding="UTF-8"?>\n'
printf '<openbox_pipe_menu>\n'

if [[ ! -r $GAMES_CONF ]]; then
	note "(games.conf not readable)"
	printf '</openbox_pipe_menu>\n'
	exit 0
fi

count=0
while IFS= read -r line || [[ -n $line ]]; do
	line=${line%$'\r'}                       # tolerate CRLF
	[[ $line =~ ^[[:space:]]*(#|$) ]] && continue

	IFS='|' read -r id name full win <<<"$line"
	id=$(trim "${id-}")
	name=$(trim "${name-}")
	full=$(trim "${full-}")
	win=$(trim "${win-}")

	[[ -n $id ]] || continue
	# Ids come from a root-owned config, but keep them boring anyway: they are
	# pasted straight into a shell command line by Openbox.
	[[ $id =~ ^[A-Za-z0-9._-]+$ ]] || continue
	[[ -n $full || -n $win ]] || continue

	[[ -n $name ]] || name=$id
	item "$name" "$LAUNCH $id --windowed"
	count=$(( count + 1 ))
done <"$GAMES_CONF"

(( count )) || note "(no games configured)"

printf '</openbox_pipe_menu>\n'
