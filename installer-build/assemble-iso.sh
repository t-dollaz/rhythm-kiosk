#!/bin/bash
# Assemble the rhythm-kiosk offline installer ISO (run as root in the build VM).
set -euxo pipefail
SRCISO=/root/debian-netinst.iso
WORK=/root/iso
OUT=/root/rhythm-kiosk-installer.iso

rm -rf "$WORK"
xorriso -osirrox on -indev "$SRCISO" -extract / "$WORK"
chmod -R u+w "$WORK"

# payload + repo + preseed
cp -r /root/rhythm-kiosk-payload "$WORK/rhythm-kiosk"
cp -r /root/rhythm-repo "$WORK/rhythm-repo"
cp /root/preseed.cfg "$WORK/preseed.cfg"

# UEFI menu: our automated entry first and default; stock menu (the "custom
# install") and accessibility entries preserved below.
G="$WORK/boot/grub/grub.cfg"
{
  echo 'set default=0'
  echo 'set timeout=10'
  echo 'menuentry "Install Rhythm Kiosk (automated, wipes the disk after one confirm)" {'
  echo '    set background_color=black'
  echo '    linux    /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg quiet'
  echo '    initrd   /install.amd/initrd.gz'
  echo '}'
  cat "$G"
} > "$G.new" && mv "$G.new" "$G"

# BIOS menu: same entry, default
T="$WORK/isolinux/txt.cfg"
{
  echo 'default rkinstall'
  echo 'label rkinstall'
  echo '  menu label ^Install Rhythm Kiosk (automated)'
  echo '  kernel /install.amd/vmlinuz'
  echo '  append auto=true priority=critical preseed/file=/cdrom/preseed.cfg vga=788 initrd=/install.amd/initrd.gz quiet'
  cat "$T"
} > "$T.new" && mv "$T.new" "$T"

# fresh checksums
( cd "$WORK" && find . -type f ! -name md5sum.txt -exec md5sum {} + > md5sum.txt )

# hybrid MBR template from the original ISO
dd if="$SRCISO" bs=1 count=432 of=/root/mbr.bin

xorriso -as mkisofs -r -V RHYTHM_KIOSK_INSTALL -o "$OUT" \
  -J -joliet-long \
  -isohybrid-mbr /root/mbr.bin \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -boot-load-size 4 -boot-info-table -no-emul-boot \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  "$WORK"
ls -la "$OUT"
echo ASSEMBLE-DONE
