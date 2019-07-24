# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=
do.devicecheck=0
do.modules=0
do.cleanup=1
do.cleanuponabort=1
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
'; } # end properties

# shell variables
block=auto;
is_slot_device=auto;
ramdisk_compression=auto;


## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/util_functions.sh
. tools/ak3-core.sh;


## AnyKernel file attributes
# set permissions/ownership for included ramdisk files
# chmod -R 750 $ramdisk/*;
# chown -R root:root $ramdisk/*;


## AnyKernel install
ui_print "- Unpacking boot img..."
split_boot;
cd $split_img

ui_print "- Detecting Root Method..."
if [ -d $MAGISKBIN ]; then
  ROOT="Magisk"; ui_print "   MagiskSU detected!"
else
  supersuimg_mount
  if [ "$supersuimg" ] || [ -d /su ]; then
    ROOT="SuperSU"; ui_print "   Systemless SuperSU detected!"
  elif [ -e "$(find /data /cache -name supersu_is_here | head -n1)" ]; then
    ROOT="SuperSU"; ui_print "   Systemless SuperSU detected!"
  elif [ -d /system/su ] || [ -f /system/xbin/daemonsu ] || [ -f /system/xbin/sugote ]; then
    ROOT="SuperSU"; ui_print "   System SuperSU detected!"
  elif [ -f /system/xbin/su ]; then
    [ "$(grep "SuperSU" /system/xbin/su)" ] && { ROOT="SuperSU"; ui_print "   System SuperSU detected!"; }
  else
    ui_print "   No Magisk or SuperSu detected!"
  fi
fi


ui_print " "
ui_print "- Chosen/Default Arguments:"
ui_print "   Keep ForceEncrypt: $KEEPFORCEENCRYPT"
ui_print "   Keep Dm-Verity: $KEEPVERITY"
ui_print "   Keep Disc Quota: $KEEPQUOTA"
ui_print " "

# Make supersu and magisk config files
if [ "$ROOT" == "Magisk" ]; then
  ui_print "- Creating/modifying .magisk file..."
  rm -f /data/.magisk /cache/.magisk /system/.magisk 2>/dev/null
  echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > $home/config
elif [ "$ROOT" == "SuperSU" ]; then
  ui_print "- Creating/modifying .supersu file..."
  if [ -f "/data/.supersu" ]; then
    ui_print "- Modifying existing .supersu file..."
    if [ "$(grep 'KEEPFORCEENCRYPT=' /data/.supersu)" ]; then
      sed -i "s/KEEPFORCEENCRYPT=.*/KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT/" /data/.supersu
    else
      echo "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT" >> /data/.supersu
    fi
    if [ "$(grep 'KEEPVERITY=' /data/.supersu)" ]; then
      sed -i "s/KEEPVERITY=.*/KEEPVERITY=$KEEPVERITY/" /data/.supersu
    else
      echo "KEEPVERITY=$KEEPVERITY" >> /data/.supersu
    fi
    if [ "$(grep 'REMOVEENCRYPTABLE=' /data/.supersu)" ]; then
      sed -i "s/REMOVEENCRYPTABLE=.*/REMOVEENCRYPTABLE=false/" /data/.supersu
    else
      echo "REMOVEENCRYPTABLE=false" >> /data/.supersu
    fi
  else
    ui_print "- Creating .supersu file..."
    echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > /data/.supersu
  fi
fi

# Gather fstabs outside of ramdisk.cpio
$bin/busybox mount -o rw,remount -t auto /system;
$bin/busybox mount -o rw,remount -t auto /vendor 2>/dev/null;
[ -f /system_root/init.rc ] && SAROOT=true || SAROOT=false
$SAROOT && FSTABS="$(find /system_root -type f \( -name "fstab.*" -o -name "*.fstab" \) -not \( -path "./system*" -o -path "./vendor*" \) | sed "s|^./||")"
FSTABS="$FSTABS /system/vendor/etc/fstab*"
for i in odm nvdata; do
  if [ "$(find /dev/block -iname $i | head -n 1)" ]; then
    mount_part $i
    [ "$i" == "nvdata" ] && FSTABS="$FSTABS /$i/fstab*" || FSTABS="$FSTABS /$i/etc/fstab*"
  fi
done

# Fstab patches
if [ `file_getprop /system/build.prop ro.build.version.sdk` -ge 26 ]; then
  for i in $FSTABS; do
    [ -f "$i" ] || continue
    ui_print "  Patching: $i"
    $KEEPFORCEENCRYPT || sed -i "
      s/forceencrypt=/encryptable=/g
      s/forcefdeorfbe=/encryptable=/g
      s/fileencryption=/encryptable=/g
    " "$i"
    $KEEPVERITY || sed -i "
      s/,verify//g
      s/verify,//g
      s/verify\b//g
      s/,avb//g
      s/avb,//g
      s/avb\b//g
      s/,support_scfs//g
      s/support_scfs,//g
      s/support_scfs\b//g
    " "$i"
    $KEEPQUOTA || sed -i "
      s/,quota//g
      s/quota,//g
      s/quota\b//g
    " "$i"
    [ "$(dirname $i)" == "/nvdata" ] && chcon u:object_r:nvdata_file:s0 $i
  done
else
  ui_print "- Disabling dm_verity in default.prop..."
  $SAROOT || $bin/magiskboot cpio ramdisk.cpio "extract default.prop default.prop"
  sed -i "s/ro.config.dmverity=.*/ro.config.dmverity=false/" default.prop
  $SAROOT && rm -f /system_root/verity_key || $bin/magiskboot cpio ramdisk.cpio "add 0644 default.prop default.prop"
fi
if [ -e ramdisk.cpio ]; then
  ui_print "- Patching ramdisk..."
  $bin/magiskboot cpio ramdisk.cpio "patch $KEEPVERITY $KEEPFORCEENCRYPT $KEEPQUOTA"
  [ "$ROOT" == "Magisk" ] && $bin/magiskboot cpio ramdisk.cpio "add 000 .backup/.magisk $home/config"
fi

# Binary patches
if ! $KEEPVERITY; then
  for dt in dtb kernel_dtb extra recovery_dtbo; do
    [ -f $dt ] && $bin/magiskboot dtb-patch $dt && ui_print "- Removing dm(avb)-verity in $dt"
  done
fi

if [ -f kernel ]; then
  # Remove Samsung RKP
  $bin/magiskboot hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054

  # Remove Samsung defex
  # Before: [mov w2, #-221]   (-__NR_execve)
  # After:  [mov w2, #-32768]
  $bin/magiskboot hexpatch kernel 821B8012 E2FF8F12
fi

for i in odm nvdata; do
  [ "$(find /dev/block -iname $i | head -n 1)" ] && { ui_print "- Unmounting $i"; umount -l /$i 2>/dev/null; rm -rf /$i; }
done

$KEEPVERITY || patch_dtbo_image
ui_print "- Repacking boot img..."
flash_boot;
