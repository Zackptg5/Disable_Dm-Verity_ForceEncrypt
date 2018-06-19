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

# Set bbe alias
case $(file_getprop /system/build.prop ro.product.cpu.abi) in
  x86_64*) alias bbe='$bin/x86_64/bbe';;
  x86*) alias bbe='$bin/x86/bbe';;
  arm64*) alias bbe='$bin/arm64/bbe';;
  *) alias bbe='$bin/arm/bbe';;
esac

# Detect dtbo and move verity containing images to proper place for ak2
dtboimage=`find /dev/block -iname dtbo$slot | head -n 1` 2>/dev/null;
[ -z $dtboimage ] || { dtboimage=`readlink -f $dtboimage`; cp -f $dtboimage /tmp/anykernel/dtbo.img; }
[ -f $split_img/boot.img-zImage ] && cp -f $split_img/boot.img-zImage /tmp/anykernel/boot.img-zImage


# begin ramdisk changes
for i in fstab.*; do
  [ -f "$i" ] || continue
  list="${list} $i"
  fstabs="${fstabs} $overlay$i"
done
if [ $(file_getprop /system/build.prop ro.build.version.sdk) -ge 26 ]; then
  for i in /system/vendor/etc/fstab.*; do
    [ -f "$i" ] || continue
    fstabs="${fstabs} $i"
  done
  list="${list} default.prop"
  patch_prop $overlay\default.prop ro.config.dmverity false
  rm -f verity_key sbin/firmware_key.cer
fi
[ -f dtb ] && list="${list} dtb"
[ -f kernel ] && list="${list} kernel"
inits="$(find . -maxdepth 1 -type f -name "*.rc")"
list="${list} $inits"

fstabs="$(echo $fstabs | sed -r "s|^ (.*)|\1|")"
list="$(echo $list | sed -r -e "s|^ (.*)|\1|" -e "s| ./| |g")"

found_fstab=false
printed=false
for fstab in $fstabs; do
	[ "$fstab" == "default.prop" ] && continue
  $printed || { ui_print "Disabling dm_verity and forced encryption in the fstab..."; printed=true; }
  if [ "$overlay" ]; then tmp=$(echo $fstab | sed "s|$overlay||"); else tmp=$fstab; fi
  ui_print "  Found fstab: $tmp"
	sed -i "s/\b\(forceencrypt\|forcefdeorfbe\|fileencryption\)=/encryptable=/g" "$fstab"
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

# disable dm_verity in init files
ui_print "Disabling dm_verity in init files..." # TEST IF WILDCARD STUFF WORKS
ui_print " "
for i in $overlay${inits}; do
  replace_string $i "# *verity_load_state" "\( *\)verity_load_state" "#\1verity_load_state";
  replace_string $i "# *verity_update_state" "\( *\)verity_update_state" "#\1verity_update_state";
done

# Remove Samsung RKP in stock kernel
if [ -f $overlay\kernel ]; then
  bbe -e "s/\x49\x01\x00\x54\x01\x14\x40\xB9\x3F\xA0\x0F\x71\xE9\x00\x00\x54\x01\x08\x40\xB9\x3F\xA0\x0F\x71\x89\x00\x00\x54\x11\x00\x18\x40\xB9\x1F\xA0\x0F\x71\x88\x01\x00\x54/\xA1\x02\x00\x54\x01\x14\x40\xB9\x3F\xA0\x0F\x71\x40\x02\x00\x54\x01\x08\x40\xB9\x3F\xA0\x0F\x71\xE0\x01\x00\x54\x00\x18\x40\xB9\x1F\xA0\x0F\x71\x81\x01\x00\x54/" -o $overlaykernel.tmp $overlaykernel
  mv -f $overlay\kernel.tmp $overlay\kernel
fi

# remove dm_verity from dtb and dtbo
for dtbs in /tmp/anykernel/boot.img-zImage $overlay\dtb /tmp/anykernel/dtbo.img; do
  [ -f $dtbs ] || continue
  ui_print "Patching $(basename $dtbs) to remove dm-verity..."
  bbe -e "s/\x2c\x76\x65\x72\x69\x66\x79/\x00\x00\x00\x00\x00\x00\x00/" -e "s/\x76\x65\x72\x69\x66\x79\x2c/\x00\x00\x00\x00\x00\x00\x00/" -e "s/\x76\x65\x72\x69\x66\x79/\x00\x00\x00\x00\x00\x00/" -o $dtbs.tmp $dtbs
  mv -f $dtbs.tmp $dtbs
done

# end ramdisk changes

ui_print " "
ui_print "Repacking boot image..."
write_boot;

## end install
