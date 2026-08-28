#!/bin/bash
set -euxo pipefail
CH=/root/closure-chroot
REPO=/root/rhythm-repo
rm -rf "$CH" "$REPO"
debootstrap --variant=minbase trixie "$CH" http://deb.debian.org/debian
echo "deb http://deb.debian.org/debian trixie main non-free-firmware" > "$CH/etc/apt/sources.list"
echo "deb http://deb.debian.org/debian-security trixie-security main non-free-firmware" >> "$CH/etc/apt/sources.list"
chroot "$CH" apt-get update
chroot "$CH" apt-get install --download-only -y \
  sudo openssh-server xserver-xorg xinit x11-xserver-utils x11-utils xfonts-base \
  openbox obconf lxterminal zenity pcmanfm dbus-x11 polkitd udiskie xwallpaper \
  usbutils unzip evtest joystick \
  pipewire-audio pipewire-alsa wireplumber alsa-utils \
  mesa-vulkan-drivers vulkan-tools \
  intel-microcode firmware-misc-nonfree \
  libxss1 libxcursor1 libxrandr2 libxinerama1 libxi6 \
  libopengl0 libjack-jackd2-0 \
  libfuse2t64 fonts-dejavu unclutter-xfixes
mkdir -p "$REPO"
cp "$CH"/var/cache/apt/archives/*.deb "$REPO"/
cd "$REPO"
dpkg-scanpackages --multiversion . > Packages
gzip -k Packages
du -sh "$REPO"; ls "$REPO" | wc -l
echo BUILD-REPO-DONE
