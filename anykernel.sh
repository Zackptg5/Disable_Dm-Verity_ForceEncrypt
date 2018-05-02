# AnyKernel2 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() {
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
} # end properties

# shell variables
ramdisk_compression=auto;
block=auto;


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


# begin ramdisk changes
for i in fstab.*; do
  [ -f "$i" ] || continue
  list="${list} $i"
  fstabs="${fstabs} $overlay/$i"
done
if [ $(grep_prop ro.build.version.sdk) -ge 26 ]; then
  for i in /system/vendor/etc/fstab.*; do
    [ -f "$i" ] || continue
    fstabs="${fstabs} $i"
  done
  list="${list} default.prop"
  patch_prop $overlay/default.prop ro.config.dmverity false
  rm -f verity_key sbin/firmware_key.cer
fi
[ -f dtb ] && list="${list} dtb"

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

# remove dm_verity from dtb and dtbo
patch_dtb $split_img/boot.img-zImage
[ -f $overlay/dtb ] && patch_dtb $overlay/dtb
[ ! -z $dtboimage ] && { cp -f $dtboimage /tmp/anykernel/dtbo.img; patch_dtb /tmp/anykernel/dtbo.img; }

# end ramdisk changes

ui_print " "
ui_print "Repacking boot image..."
write_boot;

## end install
