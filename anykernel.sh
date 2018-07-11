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

# Set magiskboot alias
case $(file_getprop /system/build.prop ro.product.cpu.abi) in
  x86*) alias magiskboot='$bin/x86/magiskboot';;
  *) alias magiskboot='$bin/arm/magiskboot';;
esac

# Detect dtbo and move to proper place for ak2
dtboimage=`find /dev/block -iname dtbo$slot | head -n 1` 2>/dev/null;
[ -z $dtboimage ] || { dtboimage=`readlink -f $dtboimage`; cp -f $dtboimage /tmp/anykernel/dtbo.img; }


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
else
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
  $printed || { ui_print "Disabling dm_verity & forced encryption in fstabs..."; printed=true; }
  if [ "$overlay" ]; then tmp=$(echo $fstab | sed "s|$overlay||"); else tmp=$fstab; fi
  ui_print "  Patching: $tmp"
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
$found_fstab || ui_print "Unable to find any fstabs!"
ui_print " "

# disable dm_verity in init files
printed=false
for i in $overlay${inits}; do
  $printed || { ui_print "Disabling dm_verity in init files..."; ui_print " "; printed=true; }
  replace_string $i "# *verity_load_state" "\( *\)verity_load_state" "#\1verity_load_state";
  replace_string $i "# *verity_update_state" "\( *\)verity_update_state" "#\1verity_update_state";
done

# Temporarily block out all custom recovery binaries/libs
mv /sbin /sbin_tmp;
# Unset library paths
OLD_LD_LIB=$LD_LIBRARY_PATH;
OLD_LD_PRE=$LD_PRELOAD;
unset LD_LIBRARY_PATH;
unset LD_PRELOAD;

# Remove Samsung RKP in stock kernel
if [ -f $overlay\kernel ]; then
  magiskboot --hexpatch $overlay\kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054
fi

# remove dm_verity from dtb and dtbo
for dtbs in $overlay\dtb /tmp/anykernel/dtbo /tmp/anykernel/dtbo.img $(ls *-dtb); do
  [ -f $dtbs ] || continue
  ui_print "Patching fstab in $(basename $dtbs) to remove dm-verity..."
  magiskboot --dtb-patch $dtbs
done

mv /sbin_tmp /sbin 2>/dev/null;
[ -z $OLD_LD_LIB ] || export LD_LIBRARY_PATH=$OLD_LD_LIB;
[ -z $OLD_LD_PRE ] || export LD_PRELOAD=$OLD_LD_PRE;

# end ramdisk changes

ui_print " "
ui_print "Repacking boot image..."
write_boot;

## end install
