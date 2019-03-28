#!/system/bin/sh
##########################################################################################
#
# Magisk Boot Image Patcher
# by topjohnwu
#
# Usage: boot_patch.sh <bootimage>
#
# The following flags can be set in environment variables:
# KEEPVERITY, KEEPFORCEENCRYPT
#
# This script should be placed in a directory with the following files:
#
# File name          Type      Description
#
# boot_patch.sh      script    A script to patch boot. Expect path to boot image as parameter.
#                  (this file) The script will use binaries and files in its same directory
#                              to complete the patching process
# util_functions.sh  script    A script which hosts all functions requires for this script
#                              to work properly
# magiskinit         binary    The binary to replace /init, which has the magisk binary embedded
# magiskboot         binary    A tool to unpack boot image, decompress ramdisk, extract ramdisk,
#                              and patch the ramdisk for Magisk support
# chromeos           folder    This folder should store all the utilities and keys to sign
#                  (optional)  a chromeos device. Used for Pixel C
#
# If the script is not running as root, then the input boot image should be a stock image
# or have a backup included in ramdisk internally, since we cannot access the stock boot
# image placed under /data we've created when previously installed
#
##########################################################################################
##########################################################################################
# Functions
##########################################################################################

# Pure bash dirname implementation
getdir() {
  case "$1" in
    */*) dir=${1%/*}; [ -z $dir ] && echo "/" || echo $dir ;;
    *) echo "." ;;
  esac
}

##########################################################################################
# Initialization
##########################################################################################

# Flags
KEEPFORCEENCRYPT=true; KEEPVERITY=true; KEEPQUOTA=true
OIFS=$IFS; IFS=\|;
ZIP="$(echo $(basename $ZIP) | tr '[:upper:]' '[:lower:]')"
while true; do
  case $ZIP in
    *fec*|*forceencrypt*) KEEPFORCEENCRYPT=false; ZIP=$(echo $ZIP | sed -r "s/(fec|forceencrypt)//g");;
    *verity*) KEEPVERITY=false; ZIP=$(echo $ZIP | sed "s/verity//g");;
    *quota*) KEEPQUOTA=false; ZIP=$(echo $ZIP | sed "s/quota//g");;
    *) break;;
  esac
done
IFS=$OIFS

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "`getdir "${BASH_SOURCE:-$0}"`"
  # Load utility functions
  . ./util_functions.sh
fi

BOOTIMAGE="$1"
[ -e "$BOOTIMAGE" ] || abort "$BOOTIMAGE does not exist!"

chmod -R 755 .

# Extract magisk if doesn't exist
[ -e magisk ] || ./magiskinit -x magisk $MAGISKBIN/magisk

##########################################################################################
# Make supersu and magisk config files
##########################################################################################

ui_print "- Creating/modifying .magisk and .supersu files..."
rm -f /.backup/.magisk /data/.magisk /cache/.magisk /system/.magisk 2>/dev/null
echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > /cache/.magisk
if [ -f "/data/.supersu" ]; then
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
  echo -e "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT\nKEEPVERITY=$KEEPVERITY\n" > /data/.supersu
fi

##########################################################################################
# Unpack
##########################################################################################

CHROMEOS=false

ui_print "- Unpacking boot image"
./magiskboot --unpack "$BOOTIMAGE"

case $? in
  1 )
    abort "! Unsupported/Unknown image format"
    ;;
  2 )
    ui_print "- ChromeOS boot image detected"
    CHROMEOS=true
    ;;
esac

##########################################################################################
# Fstab patches
##########################################################################################

if [ $(grep_prop ro.build.version.sdk) -ge 26 ]; then
  printed=false
  for i in /system/vendor/etc/fstab*; do
    [ -f "$i" ] || continue
    if ! $printed; then
      ui_print "- Disabling selections in vendor fstabs..."
      printed=true
    fi
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
  done
else
  ui_print "- Disabling dm_verity in default.prop..."
  sed -i "s/ro.config.dmverity=.*/ro.config.dmverity=false/" $INSTALLER/default.prop
  rm -f verity_key sbin/firmware_key.cer
fi

##########################################################################################
# Ramdisk patches
##########################################################################################

ui_print "- Patching ramdisk"
MAGISK_PATCHED=false
./magiskboot --cpio ramdisk.cpio "patch $KEEPVERITY $KEEPFORCEENCRYPT"

mkdir ftmp
printed=false
for i in $(cpio -t -F ramdisk.cpio | grep "fstab.\|.fstab"); do
  if ! $printed; then
    ui_print "- Disabling selections in kernel fstabs..."
    printed=true
  fi
  ui_print "   Patching $i"
  ./magiskboot --cpio ramdisk.cpio "extract $i ftmp/$i"
  $KEEPFORCEENCRYPT || sed -i "
    s/forceencrypt=/encryptable=/g
    s/forcefdeorfbe=/encryptable=/g
    s/fileencryption=/encryptable=/g
  " "ftmp/$i"
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
  " "ftmp/$i"
  $KEEPQUOTA || sed -i "
    s/,quota//g
    s/quota,//g
    s/quota\b//g
  " "ftmp/$i"
  ./magiskboot --cpio ramdisk.cpio "add 0644 $i ftmp/$i"
done
rm -rf ftmp

##########################################################################################
# Binary patches
##########################################################################################

if ! $KEEPVERITY; then
  [ -f dtb ] && ./magiskboot dtb-patch dtb && ui_print "- Removing dm(avb)-verity in dtb"
  [ -f kernel_dtb ] && ./magiskboot dtb-patch kernel_dtb && ui_print "- Removing dm(avb)-verity in dtb"
  [ -f extra ] && ./magiskboot dtb-patch extra && ui_print "- Removing dm(avb)-verity in extra-dtb"
fi

if [ -f kernel ]; then
  # Remove Samsung RKP
  ./magiskboot --hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054

  # Remove Samsung defex
  # Before: [mov w2, #-221]   (-__NR_execve)
  # After:  [mov w2, #-32768]
  ./magiskboot --hexpatch kernel 821B8012 E2FF8F12
fi

##########################################################################################
# Repack and flash
##########################################################################################

ui_print "- Repacking boot image"
./magiskboot --repack "$BOOTIMAGE" || abort "! Unable to repack boot image!"

# Sign chromeos boot
$CHROMEOS && sign_chromeos

./magiskboot --cleanup
