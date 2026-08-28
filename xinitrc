#!/usr/bin/env bash
# rhythm-kiosk :: install to ~kiosk/.xinitrc (on the target PC: /home/kiosk/.xinitrc)
#
# Run by startx. Kills every screen-blanking/power-saving path before the WM
# starts -- a rhythm game can be idle at the X input layer for a whole song
# while the player is very much still there, and a blanked TV mid-song is a
# failed run.
#
# Not executable-required (startx sources/runs it via sh), but chmod +x is harmless.

# Disable DPMS (monitor power management) entirely.
xset -dpms
# Disable the X screensaver timer.
xset s off
# Belt and braces: even if something re-enables the screensaver, do not blank.
xset s noblank

# openbox-session (not bare `openbox`) so the stock autostart / environment
# hooks in ~/.config/openbox/ are honoured. exec: when Openbox exits, X exits.
exec openbox-session
