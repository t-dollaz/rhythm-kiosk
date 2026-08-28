# Rhythm Kiosk

A setup tool that turns a PC you want to run as a dedicated rhythm game machine into an offline kiosk-style, Debian/Openbox-based system that auto boots into a game based on what USB device is plugged in. Power it on with nothing (or just a kb/m) plugged in and it boots to a minimal desktop for maintenance.

Boot priority and controller assignments are handled in .conf files editable by hand or
through included scripts that should make things a bit quicker. 

## Quickstart Guide
1. Once you've sourced a machine you want to fully dedicate to rhythm games, download rhythm-kiosk-installer.iso onto an external drive and plug it into the machine.
   (The ISO is built from the scripts in installer-build/, see INSTALL.md.)
2. Once booted, pick "Install Rhythm Kiosk".
3. Choose the drive you want to format (SSD recommended), your preferred language, set a one-time password. You won't need this again unless you manually configure different user permissions.
4. Once the install completes, you'll hit the desktop. The first-time boot script will run automatically. If you have an external drive with Linux installers for games such as Project Outfox, Clone Hero, etc, now's the time to plug it in. 
5. The script tells you the rest.
6. If you get through the script successfully, it will ask if you want to reboot now. If you configured the games and controllers to override desktop mode on boot, you're in the game now. If the game isn't fullscreen right away, use the in-game settings to set fullscreen. This setting will persist on reboot as long as you save it in the game.

You now have an extremely fast-booting DDR machine!

## First-time install

1. Easiest: write rhythm-kiosk-installer.iso to a USB stick, boot it, pick
   "Install Rhythm Kiosk". Works fully offline. (Manual path: INSTALL.md,
   stock Debian plus `sudo ./rhythm-kiosk-installer.sh`.) Either way the
   machine then boots into the desktop with no login prompt.
2. Since no games are installed yet, the first-boot setup opens automatically
   and walks through:
   - Install a game (browse for the installer file, or paste its path)
   - Assign controllers (plug them in, pick from a list)
   - Boot order and behavior (which game wins, auto-start or desktop first)
3. Every step can be skipped and done later; the setup opens again each boot
   until a game or controller is configured.
4. Reboot with a controller plugged in. Its game starts.

## First boot

Until a game or controller is configured, every boot opens the setup script in
a terminal. It walks through installing a game, assigning controllers, and
setting the boot order. Skip everything and it closes until the next boot.
If anything was configured, it ends by asking to reboot now or stay in
desktop mode.

## Desktop mode

The desktop is maintenance mode. You land here when no controller matched at
boot, when "Desktop mode" is first in the boot order, or after killing a game.
Right-click anywhere for the menu (or press Super+M or the Menu key; arrows
navigate, Enter selects).

| Menu item | What it does |
|---|---|
| Games | Live list of installed games; launches windowed for settings work |
| Terminal | Command line |
| File Manager | Browse files |
| Mapping Editor | Install games, assign controllers, set boot order |
| Kill Active Game | Stop whatever is running, no confirmation |
| Reconfigure Openbox | Reload menu config after hand-editing it |
| Session | Restart session, Reboot, Shut Down |

Wallpaper: put an image at /opt/rhythm-kiosk/wallpaper.png and it shows from
the next boot. Remove the file for a plain black desktop.

### Keyboard shortcuts

With a keyboard attached (W- is the Windows/Super key): W-0 or W-Esc kills the
running game. W-m or the Menu key opens the same menu accessible by mouse right-click. 

### Mapping Editor

Right-click, then Mapping Editor. Four functions:

1. Map controller(s) to a game: lists plugged-in USB devices (unconfigured
   first), you pick one or more, then pick the game from a list.
2. Install a new game: browse for the installer (.AppImage, .deb, tar, zip, .sh/.run installer, or a bare executable), or paste its path. USB sticks mount
   automatically and the browser starts on the newest one. The script installs
   it, asks which binary launches it, and asks where it sits in the boot order.
3. Reorder boot priorities: the game list in boot order for when multiple assigned controllers are plugged in. #1 boots first. "Desktop mode" is an entry here; put it on top
   to always boot to the desktop.
4. Uninstall a game: removes the game's files, its config entry, any
   controller mappings to it, and its boot order line.

## The scripts (/opt/rhythm-kiosk/bin/)

| Script | Role |
|---|---|
| boot-selector.sh | Runs once at boot: reads plugged-in USB, matches controllers.conf, walks boot-order.conf, launches the winner. No match means desktop, silently. Broken config means desktop plus an on-screen error naming the file |
| rhythm-launch | The only way games start and stop: kills the running game, launches the next. A game that dies within seconds of launch triggers an on-screen report with its output |
| mapping-editor.sh | The editor above; also --reorder, --install-game, --firstboot |
| games-pipemenu.sh | Generates the Games submenu live from games.conf |
| install-keybinds.sh | One-time install of the two fixed keyboard keys |
| kiosk-alert | Shows error dialogs and writes them to the permanent log |

## Configuration (/opt/rhythm-kiosk/)

| File | Format |
|---|---|
| controllers.conf | `VID:PID GAME_ID`, which controller belongs to which game |
| games.conf | `ID\|Name\|fullscreen cmd\|windowed cmd`, one line per game |
| boot-order.conf | One game id per line, top boots first; `desktop` is desktop mode |

All hand-editable if preferred. # comments allowed.

## When something breaks

Errors appear as on-screen dialogs that name the file to fix, and everything is
logged in ~/.local/state/rhythm-kiosk/kiosk.log (survives reboots). If the
graphical session itself fails, the console shows a diagnosis and holds a
prompt. Ctrl+Alt+F2 always gives a normal login. See INSTALL.md,
Troubleshooting.
