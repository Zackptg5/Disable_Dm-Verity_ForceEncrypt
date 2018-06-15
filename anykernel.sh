# AnyKernel2 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=Dm-Verity and Forced Encryption Disabler
do.devicecheck=0
do.modules=0
do.cleanup=1
do.cleanuponabort=1
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
'; } # end properties

# shell variables
block=auto;                                                         
is_slot_device=auto;
ramdisk_compression=auto;


## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. /tmp/anykernel/tools/ak2-core.sh;


## AnyKernel file attributes
# set permissions/ownership for included ramdisk files
chmod -R 750 $ramdisk/*;
chown -R root:root $ramdisk/*;


## AnyKernel install
ui_print "Unpacking boot image..."
ui_print " "
dump_boot;

# Use toybox xxd
alias xxd='/system/bin/xxd'

# Detect dtbo
dtboimage=`find /dev/block -iname dtbo$slot | head -n 1` 2>/dev/null;
[ -z $dtboimage ] || { dtboimage=`readlink -f $dtboimage`; cp -f $dtboimage /tmp/anykernel/dtbo.img; }


# begin ramdisk changes
for i in fstab.*; do
  [ -f "$i" ] || continue
  list="${list} $i"
  fstabs="${fstabs} $overlay/$i"
done
if [ $(file_getprop /system/build.prop ro.build.version.sdk) -ge 26 ]; then
  for i in /system/vendor/etc/fstab.*; do
    [ -f "$i" ] || continue
    fstabs="${fstabs} $i"
  done
  list="${list} default.prop"
  patch_prop $overlay/default.prop ro.config.dmverity false
  rm -f verity_key sbin/firmware_key.cer
fi
[ -f dtb ] && list="${list} dtb"
[ -f kernel ] && list="${list} kernel"

ui_print "Disabling forced encryption in the fstab..."
found_fstab=false
for fstab in $fstabs; do
	[ "$fstab" == "default.prop" ] && continue
  ui_print "  Found fstab: $(echo $fstab | sed "s|$overlay||")"
	sed -i "
		s/\b\(forceencrypt\|forcefdeorfbe\|fileencryption\)=/encryptable=/g
	" "$fstab"
	found_fstab=true
done
$found_fstab || ui_print "Unable to find the fstab!"

ui_print "Disabling dm-verity in the fstab..."
found_fstab=false
for fstab in $fstabs; do
  [ "$fstab" == "default.prop" ] && continue
	ui_print "  Found fstab: $(echo $fstab | sed "s|$overlay||")"
	sed -i "
		s/,verify\b//g
		s/\bverify,//g
		s/\bverify\b//g
		s/,support_scfs\b//g
		s/\bsupport_scfs,//g
		s/\bsupport_scfs\b//g
	" "$fstab"
	found_fstab=true
done
$found_fstab || ui_print "Unable to find the fstab!"
ui_print " "

# Remove Samsung RKP in stock kernel
if [ -f $overlay/kernel ]; then
  xxd -p $overlay/kernel | sed 's/49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054/A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054/' | xxd -r -p > $overlay/kernel.tmp
  mv -f $overlay/kernel.tmp $overlay/kernel
fi

# remove dm_verity from dtb and dtbo
[ -f $split_img/boot.img-zImage ] && cp -f $split_img/boot.img-zImage /tmp/anykernel/boot.img-zImage
for dtbs in /tmp/anykernel/boot.img-zImage $overlay/dtb /tmp/anykernel/dtbo.img; do
  [ -f $dtbs ] || continue
  xxd -p $dtbs | [ "$(sed -n '/766572696679/p')" ] && VERITY=true
  if $VERITY; then
    ui_print "Patching $(basename $dtbs) to remove dm-verity..."
    xxd -p $dtbs | sed -e 's/2c766572696679/00000000000000/g' -e 's/7665726966792c/00000000000000/g' -e 's/766572696679/000000000000/g' | xxd -r -p > $dtbs.tmp
    mv -f $dtbs.tmp $dtbs
  fi
done
# end ramdisk changes

ui_print " "
ui_print "Repacking boot image..."
write_boot;

## end install
