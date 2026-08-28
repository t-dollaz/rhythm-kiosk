# Rhythm Kiosk PC — Bring-Up Checklist

Bare machine to working kiosk. Easiest: boot the installer ISO (next section).
Manual path: one stock Debian install (three caveats), one script, one reboot.
The numbered sections after step 2 document what gets set up, for reference
and manual repair; they assume this folder was copied to the target PC.

---

## The installer ISO (easiest path)

`rhythm-kiosk-installer.iso` (next to this folder) is a remastered Debian 13
netinst that does steps 1 and 2 for you, **fully offline**: write it to a USB
stick (Rufus, or `dd if=rhythm-kiosk-installer.iso of=/dev/sdX bs=4M`), boot
it, and pick "Install Rhythm Kiosk (automated)". It asks only for language/
keyboard, the kiosk password, and one write-changes-to-disk confirm; all
packages come from a repo bundled in the image. The stock Debian entries below
it in the boot menu are the custom/manual path. After the reboot the guided
first-boot setup opens; game installers can come on a second USB stick.

Rebuilding the ISO after package changes: `installer-build/` has the preseed
and the two build scripts (run on a Debian 13 box: build-repo.sh, then
assemble-iso.sh).

## 0. Target hardware prep (HP EliteDesk 800 G3 Mini + Pixio PX275h)

Before installing anything:

- **BIOS** (F10 at boot): disable Secure Boot (frictionless Debian install); set **After Power Loss -> Power On** if the outlet/switch should control the machine; leave legacy USB support on.
- **RAM**: confirm **dual-channel** (2 SODIMMs, not 1x8GB) — `sudo dmidecode -t memory` after install, or open the lid. The HD 630 iGPU is bandwidth-limited; single-channel costs ~20-30% GPU performance at 1440p.
- **Storage**: use an SSD (M.2 NVMe slot or 2.5" bay). Boot time is part of the game-switch workflow (replug + reboot).
- **Video**: PC DisplayPort -> monitor DisplayPort, DIRECT. Never through the soundbar (1080p-class HDMI switching would cap the 1440p@95 panel).
- **Audio**: PC front 3.5mm -> RCA into the SA-WCT150 sub (see step 3 notes).
- **FreeSync does not apply**: Intel Gen9 iGPU + X11 = no VRR. Per-game fixed refresh via xrandr instead (e.g. 95Hz for Clone Hero/OutFox; 60Hz for any 60Hz-content emulator) — set per game in `games.conf` launch commands.

## 1. Install minimal Debian stable

Use the Debian **netinst** image. A normal install, with exactly three caveats:

1. **Root password: leave BOTH fields empty.** This disables the root account
   and gives the first user sudo, which the setup script needs.
2. **Name the user account `kiosk`** (full name and username). It becomes the
   autologin kiosk user; the password you pick here gates SSH/console access.
3. At software selection (`tasksel`): **UNCHECK "Debian desktop environment"**
   and every desktop task; **CHECK "SSH server"** (optional but handy) and
   **"standard system utilities"**.

Language, keyboard, locale, accessibility and partitioning (guided LVM is
fine) are the normal Debian experience -- choose whatever suits.

## 2. Run the setup script

Copy this whole folder onto the machine (USB stick, scp, anything), then:

From a USB stick on the fresh text console:

```bash
sudo mount /dev/sdb1 /mnt        # lsblk shows the stick's name if not sdb1
cp -r /mnt/rhythm-kiosk ~ && cd ~/rhythm-kiosk
sudo ./rhythm-kiosk-installer.sh
```

It installs all packages (network required), passwordless sudo, autologin, the
session chain, Openbox config and keybinds, `/opt/rhythm-kiosk` with EMPTY
game/controller configs, the udev and polkit rules, and the wallpaper if
`wallpaper.png` is present. It is safe to re-run. Answer the reboot question at
the end; the machine comes back in desktop mode with the guided first-boot
setup open.

The sections below describe what the script sets up, for reference and manual
repair.

## 2. Create the `kiosk` user

```bash
sudo adduser kiosk
sudo usermod -aG sudo,audio,video,input,plugdev kiosk
```

`input` + `plugdev` matter: the games and the mapping editor read controllers directly.

## 3. Install packages

```bash
sudo apt update
sudo apt install -y \
  xserver-xorg xinit x11-xserver-utils x11-utils xfonts-base \
  openbox obconf lxterminal zenity pcmanfm dbus-x11 polkitd udiskie xwallpaper \
  usbutils unzip evtest joystick \
  pipewire-audio pipewire-alsa wireplumber alsa-utils \
  mesa-vulkan-drivers vulkan-tools \
  intel-microcode firmware-misc-nonfree \
  libxss1 libxcursor1 libxrandr2 libxinerama1 libxi6 \
  libfuse2t64 fonts-dejavu unclutter-xfixes

# Optional but sensible in the Mini's cramped chassis:
sudo apt install -y thermald
```

If `libfuse2t64` is not found (older Debian), the package is named `libfuse2`.
If `polkitd` is not found (older Debian), it is `policykit-1`.

Per-game / per-need extras:

```bash
# Optional examples -- NOT pre-included; install only if wanted:
#   sudo apt install -y dolphin-emu    # GameCube emulator (Donkey Konga etc.)
#   sudo apt install -y antimicrox     # gamepad -> keyboard mapper
```

Notes:
- `x11-utils` provides **`xmessage`**, which `bin/kiosk-alert` uses to put a failure dialog on screen. Without it every error is invisible on a TV with no keyboard — treat it as required, not optional.
- `libfuse2t64` (or `libfuse2`) is required for AppImages (Clone Hero / OutFox ship as AppImages or tarballs depending on release).
- `xfonts-base` is what `xmessage` renders with — only a *recommends* of Xorg, so it is listed explicitly. Without it kiosk-alert dialogs can silently fail to draw.
- `polkitd` is what lets an unprivileged local session run `systemctl reboot`/`poweroff` — a minimal no-DE install does not include it, and without it the menu's Reboot/Shut Down always fail (loudly, but needlessly).
- `dbus-x11` provides the session bus; without it pcmanfm and friends stall or misbehave.
- `xwallpaper` sets an optional background: drop an image at
  `/opt/rhythm-kiosk/wallpaper.png` and it appears at next session start
  (one-shot at login, no resident process; jpg works too if named .png-less
  and the autostart line is adjusted).
- `udiskie` automounts plugged-in USB storage to /media/kiosk/<label> (with the
  polkit rule from step 10), so installers can be loaded from a stick. FAT32
  and exFAT sticks work out of the box; NTFS needs `ntfs-3g` if you want it.
- `lxterminal` is the kiosk terminal (light, quick). `zenity` provides the
  file-picker dialog the installer flow uses to choose installer files, so the
  terminal needs no drag-and-drop support.
- `mesa-vulkan-drivers` gives the HD 630 iGPU its Vulkan backend (emulators want it; `vulkan-tools` adds `vulkaninfo` for the smoke test). Not installed by default with Xorg.
- `intel-microcode` + `firmware-misc-nonfree` need the `non-free-firmware` apt component (enabled by default by the Debian 12+ installer).
- `libxss1 libxcursor1 libxrandr2 libxinerama1 libxi6`: the usual missing-on-minimal X client libs for Unity builds (Clone Hero) and other prebuilt game binaries.
- `evtest` + `joystick` (jstest): controller diagnostics — also how the LTEK/CRKD VID:PIDs get captured (step 13).
- `unclutter-xfixes` hides the idle mouse cursor (add `unclutter --timeout 2 &` to the Openbox autostart, above the boot-selector line).
- **libusb**: if the Mayflash GC adapter (`057e:0337`) is used (e.g. with a manually installed Dolphin), its device node must be user-accessible — that is what the udev rule in step 10 does. Never run an emulator as root to work around permissions.
- Sound: **PipeWire** (with `pipewire-alsa` + WirePlumber) — the Debian-stable default and the lower-latency choice for rhythm play. All three games see a Pulse-compatible server; nothing per-game to configure. `alsa-utils` keeps `alsamixer` available for maintenance-mode volume fixes.
- **Audio path (decided)**: PC front 3.5mm jack -> 3.5mm-to-RCA cable -> Sony SA-WCT150 phono inputs. The analog codec is an always-present sink, immune to DisplayPort re-negotiation during per-game refresh switches. Do NOT route audio (or video) through the soundbar's HDMI — it is 1080p-class and would cap the display. Set the default sink once: `wpctl status` to find the analog sink id, `wpctl set-default <id>`.

## 4. Passwordless sudo for `kiosk` (sudoers drop-in)

```bash
sudo cp ~/rhythm-kiosk-staging/010_kiosk-nopasswd /etc/sudoers.d/010_kiosk-nopasswd
sudo chown root:root /etc/sudoers.d/010_kiosk-nopasswd
sudo chmod 0440      /etc/sudoers.d/010_kiosk-nopasswd
sudo visudo -c
```

**`visudo -c` is not optional.** It must print `/etc/sudoers.d/010_kiosk-nopasswd: parsed OK` (and `/etc/sudoers: parsed OK`) **before you close this shell**. A syntactically broken file in `/etc/sudoers.d/` disables `sudo` *entirely* — including the `sudo` you would use to fix it. Keep a root shell open until it parses, or recover via GRUB recovery mode.

The whole file is one grant, the RetroPie `010_pi-nopasswd` pattern:

```
kiosk ALL=(ALL) NOPASSWD: ALL
```

Why: the mapping editor writes root-owned files under `/opt/rhythm-kiosk`, and it runs in a throwaway terminal window with no reliable keyboard. A hidden `sudo` password prompt there looks exactly like a hang. The editor therefore uses `sudo -n` only (never prompts) and **fails loudly naming this file** if sudo is not usable.

Also check:

- mode must be `0440`, owner `root:root` — sudo ignores files that are group/world-writable
- the filename must contain **no `.`** and no trailing `~` — sudo skips those too
- verify as the kiosk user: `sudo -u kiosk sudo -n true` returns 0 silently

**SSH caveat:** this makes the `kiosk` account password the only thing between a remote login and root. If you enabled the SSH server in step 1, switch it to key auth — `PasswordAuthentication no` in `/etc/ssh/sshd_config`, then `sudo systemctl restart ssh`. With no SSH server (the default for this build) physical access is already root access and this changes nothing.

The boot-into-game path uses **no sudo at all**; this grant exists purely for maintenance mode.

## 5. Getty autologin on tty1

```bash
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo cp ~/rhythm-kiosk-staging/autologin.conf \
        /etc/systemd/system/getty@tty1.service.d/autologin.conf
sudo systemctl daemon-reload
```

The drop-in must clear the stock `ExecStart` before setting its own:

```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
```

Verify after reboot with `systemctl status getty@tty1`.

> **Why `sudo install` and not `sudo -u kiosk cp`** (found in the VM test run):
> Debian 12+ creates home directories mode **0700**, so the `kiosk` user cannot read
> files staged under `~tyler/`. `install -o kiosk -g kiosk` lets root do the copy while
> the file still ends up owned by `kiosk`.

## 6. `.bash_profile` startx stanza

```bash
sudo install -o kiosk -g kiosk -m 0644 ~/rhythm-kiosk-staging/bash_profile-stanza /home/kiosk/.bash_profile
```

The stanza must guard on tty1 so SSH logins never try to start X:

```bash
if [[ -z "$DISPLAY" && "$XDG_VTNR" == 1 ]]; then
  exec startx
fi
```

## 7. `.xinitrc`

```bash
sudo install -o kiosk -g kiosk -m 0755 ~/rhythm-kiosk-staging/xinitrc /home/kiosk/.xinitrc
```

It disables blanking/DPMS and execs the session:

```bash
xset -dpms; xset s off; xset s noblank
exec openbox-session
```

## 8. Openbox config

```bash
sudo install -d -o kiosk -g kiosk /home/kiosk/.config/openbox
sudo install -o kiosk -g kiosk -m 0755 ~/rhythm-kiosk-staging/openbox/autostart /home/kiosk/.config/openbox/autostart
# rc.xml: the stock Openbox config; step 9 injects the two fixed kiosk
# keybinds (kill-game, open-menu) with install-keybinds.sh.
sudo install -o kiosk -g kiosk -m 0644 /etc/xdg/openbox/rc.xml /home/kiosk/.config/openbox/rc.xml
sudo install -o kiosk -g kiosk -m 0644 ~/rhythm-kiosk-staging/openbox/menu.xml /home/kiosk/.config/openbox/menu.xml
chmod +x /home/kiosk/.config/openbox/autostart
```

| File | Role |
|---|---|
| `autostart` | one-shot: runs `/opt/rhythm-kiosk/bin/boot-selector.sh` |
| `bin/install-keybinds.sh` | one-time injection of the two fixed keybinds (kill-game W-0/W-Esc, open-menu W-m/Menu) |
| `menu.xml` | maintenance root menu: terminal, file manager, mapping editor, Games pipe menu |

If you edit these later: `openbox --reconfigure` (no logout needed).

## 9. `/opt/rhythm-kiosk` layout

```bash
sudo mkdir -p /opt/rhythm-kiosk/{bin,games}
sudo cp ~/rhythm-kiosk-staging/bin/* /opt/rhythm-kiosk/bin/
sudo chmod 755 /opt/rhythm-kiosk/bin/*
sudo cp ~/rhythm-kiosk-staging/controllers.conf /opt/rhythm-kiosk/controllers.conf
sudo cp ~/rhythm-kiosk-staging/boot-order.conf /opt/rhythm-kiosk/boot-order.conf
# inject the two fixed keybinds (kill-game, open-menu) into rc.xml
sudo -u kiosk -H /opt/rhythm-kiosk/bin/install-keybinds.sh
sudo cp ~/rhythm-kiosk-staging/games.conf       /opt/rhythm-kiosk/games.conf
sudo chmod 644 /opt/rhythm-kiosk/*.conf
sudo ln -sf /opt/rhythm-kiosk/bin/rhythm-launch /usr/local/bin/rhythm-launch
```

Final layout:

| Path | Purpose |
|---|---|
| `/opt/rhythm-kiosk/controllers.conf` | `VID:PID GAME_ID` — membership only, no priority |
| `/opt/rhythm-kiosk/boot-order.conf` | one `GAME_ID` per line — **top line boots first** |
| *(reserved)* `desktop` in boot-order.conf | boot to the bare desktop instead of a game; on TOP = always boot to desktop |
| `/opt/rhythm-kiosk/games.conf` | `GAME_ID\|DISPLAY_NAME\|FULLSCREEN_CMD\|WINDOWED_CMD` |
| `/opt/rhythm-kiosk/bin/boot-selector.sh` | one-shot boot-time device match + launch |
| `/opt/rhythm-kiosk/bin/rhythm-launch` | kill-then-exec launch wrapper (hotkeys + menu) |
| `/opt/rhythm-kiosk/bin/games-pipemenu.sh` | Openbox pipe menu generated from `games.conf` |
| `/opt/rhythm-kiosk/bin/mapping-editor.sh` | interactive controller/game mapping editor |
| `/opt/rhythm-kiosk/bin/kiosk-alert` | on-screen failure dialog (`xmessage`) + append to `~/.local/state/rhythm-kiosk/kiosk.log` |
| `/etc/sudoers.d/010_kiosk-nopasswd` | passwordless sudo for `kiosk` (installed in step 4, `0440 root:root`) |
| `/opt/rhythm-kiosk/games/<game-id>/` | installed game payloads |

Writes to everything under `/opt/rhythm-kiosk` go through `sudo -n`, which is what step 4's drop-in is for. If that file is missing the mapping editor refuses to start and says so by name — it will never sit on a password prompt.

## 10. udev rule (permissions only — no `RUN+=`)

```bash
sudo cp ~/rhythm-kiosk-staging/99-rhythm-perms.rules /etc/udev/rules.d/99-rhythm-perms.rules
# USB-stick automount authorization (game installers from removable media)
sudo install -m 0644 ~/rhythm-kiosk-staging/49-rhythm-kiosk-udisks.rules /etc/polkit-1/rules.d/49-rhythm-kiosk-udisks.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The rule opens up the Mayflash GC adapter for user-space (libusb) access without root: the `usb_device` node gets `MODE="0666"` (per the Dolphin wiki's own rule), and the `hidraw` node gets `MODE="0660"` with `GROUP="plugdev"`. **Nothing in udev launches anything** — udev kills long-lived children and has no session/display; launching is the boot selector's job.

Verify with the adapter plugged in:

```bash
lsusb | grep -i 057e
# the adapter's usb_device node should be mode 0666 (crw-rw-rw-)
ls -l /dev/bus/usb/*/*
# its hidraw node should be mode 0660, group plugdev
ls -l /dev/hidraw*
```

## 11. Install the games

Preferred route once the system is up: boot to maintenance mode, right-click -> **Mapping Editor**, and drag each installer onto the terminal. It installs into `/opt/rhythm-kiosk/games/<id>/` and writes both conf files for you.

Manual equivalents:

- **Clone Hero** — download the Linux build (tarball/AppImage) from the official site. Extract to `/opt/rhythm-kiosk/games/clonehero/`. Launch binary is `Clone Hero` / `Clone Hero.x86_64`. First run: set Fullscreen + the correct display in its video settings.
- **Project OutFox** — official Linux release (AppImage or tarball) to `/opt/rhythm-kiosk/games/outfox/`. OutFox stores its own config in `~/.outfox` (or the portable dir) — set resolution and fullscreen there once.
- **Dolphin** (optional, not pre-included) — `sudo apt install dolphin-emu`, then
  add it in the Mapping Editor by typing `dolphin-emu` as the launch command.
  Configure with keyboard/mouse: game list directory, GameCube Adapter for Wii U
  in Port 1, graphics backend and fullscreen.

### First-boot guided setup

On a machine where games.conf or controllers.conf has no entries yet (a fresh
image), the Openbox autostart launches a **one-time guided setup** in a terminal
window: install a game (drag-and-drop), assign controllers, choose whether games
auto-start on boot or the kiosk always boots to the desktop. Every step is
skippable; if everything is skipped, the closing text explains how to do it
later from the right-click menu (mouse, or Super+M / Menu key), and the setup
offers itself again next boot — it stops once a game or a controller is
configured (stateless: the configs are the only check). Manual run:
`mapping-editor.sh --firstboot`.

## 12. First reboot / smoke test

```bash
sudo reboot
```

Expected: no login prompt, no display manager; a bare Openbox desktop appears, and if a mapped controller was plugged in at boot the matching game launches fullscreen.

Checks:
- No controller plugged in -> bare Openbox desktop = **maintenance mode**. Right-click the desktop for the menu.
- Mapped controller plugged in -> game launches.
- Two mapped controllers plugged in -> the game listed higher in `boot-order.conf` wins.
- With a keyboard attached, W-0/W-Esc kills the running game to the desktop and W-m opens the menu.

If getty+startx misbehaves, the documented fallback is LightDM with an autologin session — same Openbox session, different launcher.

## 13. Remaining TODOs (blocked on hardware / on the TV)

| # | TODO | How |
|---|---|---|
| 1 | **LTEK dance pad VID:PID** | Plug it in **alone**, run `lsusb`, note the `ID xxxx:yyyy`. Fill it into the existing placeholder line in `controllers.conf` (`0000:0000 outfox`). |
| 2 | **CRKD guitar VID:PID** | Same, alone. It may enumerate as a generic XInput device — if its ID collides with something else, use `udevadm info -a -n /dev/input/eventN` to find a distinguishing attribute. Fill it into the existing `0000:0000 clonehero` placeholder line in `controllers.conf` — same game as the X-plorer. |
| 3 | **Per-game A/V latency calibration** | Must be done on the actual TV, not a monitor. Clone Hero: in-game calibration screen. OutFox: `Options -> Adjust Sync/Offset` (global offset + per-song). Emulators: audio backend latency + any TV "game mode" toggle. Rhythm games are unplayable without this — treat it as part of bring-up, not polish. |
| 4 | **Donkey Konga ISO** (only if Dolphin is added) | Place under a fixed directory and add it to Dolphin's game list. |
| 5 | **Bongo navigation of Dolphin's UI** (only if Dolphin is added; deferred) | Dolphin boots to its game list, which needs keyboard/mouse to navigate. Later: an antimicrox profile mapping the bongos to arrow keys/Enter, started from `launch-dolphin.sh` and killed with it. Explicitly out of scope for initial bring-up. |

---

## Troubleshooting

Nothing in this system fails quietly on purpose: the only intentionally silent path is "no controller matched -> maintenance desktop". Anything else should have produced an on-screen `xmessage` naming the file to fix, and a line in `~/.local/state/rhythm-kiosk/kiosk.log`. **Read that log first** — it is the single place every failure is recorded.

### Access paths that always exist

Reach these before assuming the box is bricked:

- **Ctrl+Alt+F2** — a normal login prompt on tty2. The autologin drop-in touches **tty1 only**, so tty2 is untouched no matter how badly the X session is broken.
- **SSH**, if you enabled the server in step 1 (use key auth — see step 4's SSH caveat).
- **GRUB recovery mode** — hold Shift at boot, pick the recovery entry, get a root shell. This is the way back from a broken `/etc/sudoers.d/` file.

### A login prompt appears at boot

The getty autologin drop-in is not taking effect.

```bash
systemctl status getty@tty1        # expect the agetty line with --autologin kiosk
systemctl cat getty@tty1           # confirm the drop-in is listed and has ExecStart= (empty) first
```

Log in manually as `kiosk` — everything else still works, since `.bash_profile` starts X on login regardless of *how* you logged in. Fix: re-check step 5 (the empty `ExecStart=` line is mandatory) then `sudo systemctl daemon-reload`.

### Black screen / X never starts

The startx stanza is supervised: on failure it prints a banner and **holds a shell on tty1** instead of respawning. If you get that banner, you already have a shell — start reading:

```bash
sudo tail -40 /var/log/Xorg.0.log      # (EE) lines = driver/display problems
tail -40 ~/.xsession-errors            # openbox / autostart / game errors
tail -40 ~/.local/state/rhythm-kiosk/kiosk.log
```

If tty1 is dead *and* blank, getty likely hit systemd's start limit:

```bash
sudo systemctl reset-failed getty@tty1
sudo systemctl restart getty@tty1
```

(A respawn loop is exactly why the stanza holds a shell rather than re-exec'ing `startx`.)

### Mapping editor says "sudo is not usable without a password"

The sudoers drop-in is missing, misnamed, or has the wrong mode. Fix `/etc/sudoers.d/010_kiosk-nopasswd` per **step 4** — including `sudo visudo -c`. The editor stops before doing any work, so nothing is half-written.

### Mapping editor aborted mid-write

It stops at the first failed write and names the file. `games.conf` and `controllers.conf` are a matched pair: check that the game id it was writing exists in `games.conf` **and** that the controller lines in `controllers.conf` point at it. Delete any leftover `*.conf.tmp.*` files, then re-run the editor.

### A game launches, then dies instantly

`rhythm-launch` watches the game after exec'ing it; a fast death raises an alert instead of dropping you at a silent desktop. The dialog and `~/.local/state/rhythm-kiosk/kiosk.log` carry the **tail of the game's own output** plus the `games.conf` path holding the command that failed. Usual causes: wrong binary path in `games.conf` (the mapping editor's validation warns about this), a missing `libfuse2` for an AppImage, or a game that needs a display setting it cannot get.

Test the command by hand from a terminal in maintenance mode — it fails the same way there, with the error in front of you.

### Everything else

`kiosk.log` self-trims, so it is safe to leave running forever; it will not fill the disk. When reporting a problem, attach it — it is the whole story in one file.
