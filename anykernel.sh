# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=1
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties

# shell variables
block=auto;
is_slot_device=auto;
ramdisk_compression=auto;


## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;
. tools/util_functions.sh

## AnyKernel file attributes
# set permissions/ownership for included ramdisk files
# chmod -R 750 $ramdisk/*;
# chown -R root:root $ramdisk/*;


## AnyKernel install
ui_print "- Detecting Root Method..."
if [ -d $MAGISKBIN ]; then
  ROOT="Magisk"; ui_print "   MagiskSU detected!"
else
  if [ "$supersuimg" ] || [ -d /su ] || [ -e "$(find /data /cache -name supersu_is_here | head -n1)" ] || [ -d /system/su ] || [ -f /system/xbin/daemonsu ] || [ -f /system/xbin/sugote ]; then
    ROOT="SuperSU"; ui_print "   SuperSU detected!"
  elif [ -f /system/xbin/su ]; then
    [ "$(grep "SuperSU" /system/xbin/su)" ] && { ROOT="SuperSU"; ui_print "   SuperSU detected!"; } || ui_print "   No Magisk or SuperSu detected!"
  else
    ui_print "   No Magisk or SuperSu detected!"
  fi
fi

ui_print "- Unpacking boot img..."
split_boot;
cd $split_img

# Check ramdisk status
if [ -e ramdisk.cpio ]; then
  $bin/magiskboot cpio ramdisk.cpio test
  STATUS=$?
else
  # Stock A only system-as-root
  STATUS=0
fi

if [ $((STATUS & 8)) -ne 0 ]; then
  # Possibly using 2SI, export env var
  export TWOSTAGEINIT=true
fi

# Make supersu and magisk config files
make_config() {
  case $ROOT in
    "Magisk") local FILE=$home/config FILE2=".magisk";;
    "SuperSU") local FILE=/data/.supersu FILE2=".supersu";;
    *) ui_print "- Creating .magisk and .supersu files..."
       echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > $home/config
       cp -f $home/config /data/.supersu
       echo "REMOVEENCRYPTABLE=$REMOVEENCRYPTABLE" >> /data/.supersu
       return 0;;
  esac
  if [ -f $FILE ]; then
    ui_print "- Modifying existing $FILE2 file..."
    for i in "KEEPFORCEENCRYPT" "KEEPVERITY" "REMOVEENCRYPTABLE"; do
      local j=$(eval echo "\$$i")
      [ "$i" == "REMOVEENCRYPTABLE" ] && [ "$ROOT" == "Magisk" ] && continue
      if [ "$(grep "$i=" $FILE)" ]; then
        sed -i "s/$i=.*/$i=$j/" $FILE
      else
        echo "$i=$j" >> $FILE
      fi
    done
  else
    ui_print "- Creating $FILE2 file..."
    echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > $FILE
    [ "$ROOT" == "SuperSU" ] && echo "REMOVEENCRYPTABLE=$REMOVEENCRYPTABLE" >> $FILE
  fi
}

if [ "$ROOT" == "Magisk" ]; then
  if [ -e ramdisk.cpio ] && $bin/magiskboot cpio ramdisk.cpio "exists .backup/.magisk"; then
    $bin/magiskboot cpio ramdisk.cpio "extract .backup/.magisk $home/config"
  else
    for i in /data/.magisk /cache/.magisk /system/.magisk; do
      [ -f $i ] && cp -f $i $home/config && break
    done
  fi
  rm -f /data/.magisk /cache/.magisk /system/.magisk 2>/dev/null
  make_config
else
  make_config
fi

# Fstab patches
FSTABS="$(find $VEN/etc -type f \( -name "fstab*" -o -name "*.fstab" \) | sed "s|^./||")"
[ -z "$FSTABS" ] || FSTABS="$FSTABS "
for i in odm nvdata; do
  if [ "$(find /dev/block -iname $i | head -n 1)" ]; then
    mount_part $i
    [ "$i" == "nvdata" ] && FSTABS="$FSTABS/$i/fstab*" || FSTABS="$FSTABS/$i/etc/fstab*"
  fi
done

if [ `file_getprop /system/build.prop ro.build.version.sdk` -ge 26 ]; then
  [ -z "$FSTABS"  ] || ui_print "- Patching fstabs:"
  for i in $FSTABS; do
    [ -f "$i" ] || continue
    ui_print "   $i"
    PERM="$(ls -Z $i | awk '{print $1}')"
    $KEEPFORCEENCRYPT || sed -ri "
      s/forceencrypt=|forcefdeorfbe=|fileencryption=/=/g
    " "$i"
    $KEEPVERITY || sed -ri "
      s/,verifyatboot|verifyatboot,|verifyatboot\b//g
      s/,verify|verify,|verify\b//g
      s/,avb_keys|avb_keys,|avb_keys\b//g
      s/,avb|avb,|avb\b//g
      s/,support_scfs|support_scfs,|support_scfs\b//g
      s/,fsverity|fsverity,|fsverity\b//g
    " "$i"
    $KEEPQUOTA || sed -ri "
      s/,quota|quota,|quota\b//g
    " "$i"
    chcon $PERM $i
  done
elif [ -e ramdisk.cpio ]; then
  ui_print "- Disabling dm_verity in default.prop..."
  $bin/magiskboot cpio ramdisk.cpio "extract default.prop default.prop"
  sed -i "s/ro.config.dmverity=.*/ro.config.dmverity=false/" default.prop
  $bin/magiskboot cpio ramdisk.cpio "add 0644 default.prop default.prop"
fi
if [ -e ramdisk.cpio ]; then
  ui_print "- Patching ramdisk..."
  $bin/magiskboot cpio ramdisk.cpio patch
  [ "$ROOT" != "SuperSU" ] && $bin/magiskboot cpio ramdisk.cpio "mkdir 000 .backup" "add 000 .backup/.magisk $home/config"
fi
if [ "$ROOT" != "SuperSU" ]; then
  if $DATA; then
    cp -f $home/config /data/.magisk
  else
    cp -f $home/config /cache/.magisk
  fi
fi

# Kernel cmdline patch
[ -f header ] && sed -i -e "s/Android:#[a-zA-Z0-9]* //" -e "s/android-verity/linear/" header

# Dtb patches
for dt in dtb kernel_dtb extra recovery_dtbo; do
  [ -f $dt ] && $bin/magiskboot dtb $dt patch && ui_print "- Patching fstab in $dt"
done

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

patch_dtb_partitions
ui_print "- Repacking boot img..."
flash_boot;
