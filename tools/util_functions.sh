#########################################
#
# Magisk General Utility Functions
# by topjohnwu
#
#########################################

###################
# Helper Functions
###################

toupper() {
  echo "$@" | tr '[:lower:]' '[:upper:]'
}

is_mounted() {
  grep -q " `readlink -f $1` " /proc/mounts 2>/dev/null
  return $?
}

#######################
# Installation Related
#######################

find_block() {
  for BLOCK in "$@"; do
    DEVICE=`find /dev/block -type l -iname $BLOCK | head -n 1` 2>/dev/null
    if [ ! -z $DEVICE ]; then
      readlink -f $DEVICE
      return 0
    fi
  done
  # Fallback by parsing sysfs uevents
  for uevent in /sys/dev/block/*/uevent; do
    local DEVNAME=`file_getprop $uevent DEVNAME`
    local PARTNAME=`file_getprop $uevent PARTNAME`
    for BLOCK in "$@"; do
      if [ "`toupper $BLOCK`" = "`toupper $PARTNAME`" ]; then
        echo /dev/block/$DEVNAME
        return 0
      fi
    done
  done
  return 1
}

mount_part() {
  local PART=$1
  local POINT=/${PART}
  [ -L $POINT ] && rm -f $POINT
  mkdir $POINT 2>/dev/null
  is_mounted $POINT && return
  ui_print "- Mounting $PART"
  mount -o rw $POINT 2>/dev/null
  if ! is_mounted $POINT; then
    local BLOCK=`find_block $PART$SLOT`
    mount -o rw $BLOCK $POINT
  fi
  is_mounted $POINT || abort "! Cannot mount $POINT"
}

get_flags() {
  # override variables
  if [ -z $KEEPVERITY ]; then
    if [ -f /system_root/init.rc ]; then
      KEEPVERITY=true
      ui_print "- System-as-root, keep dm/avb-verity"
    else
      KEEPVERITY=false
    fi
  fi
  if [ -z $KEEPFORCEENCRYPT ]; then
    grep ' /data ' /proc/mounts | grep -q 'dm-' && FDE=true || FDE=false
    [ -d /data/unencrypted ] && FBE=true || FBE=false
    # No data access means unable to decrypt in recovery
    if $FDE || $FBE || ! $DATA; then
      KEEPFORCEENCRYPT=true
      ui_print "- Encrypted data, keep forceencrypt"
    else
      KEEPFORCEENCRYPT=false
    fi
  fi
  [ -z $KEEPQUOTA ] && KEEPQUOTA=true
}

patch_dtbo_image() {
  local DTBOIMAGE=`find_block dtbo$SLOT`
  if [ ! -z $DTBOIMAGE ]; then
    ui_print "- DTBO image: $DTBOIMAGE"
    if $bin/magiskboot --dtb-test $DTBOIMAGE; then
      ui_print "- Patching DTBO to remove avb-verity"
      $bin/magiskboot --dtb-patch $DTBOIMAGE
      return 0
    fi
  fi
  return 1
}

check_data() {
  DATA=false
  DATA_DE=false
  if grep ' /data ' /proc/mounts | grep -vq 'tmpfs'; then
    # Test if data is writable
    touch /data/.rw && rm /data/.rw && DATA=true
  fi
}

########
# Flags
########

OIFS=$IFS; IFS=\|;
ZIPFILE="$(echo $(basename $ZIPFILE) | tr '[:upper:]' '[:lower:]')"
while true; do
  case $ZIPFILE in
    *fec*|*forceencrypt*) KEEPFORCEENCRYPT=false; ZIPFILE=$(echo $ZIPFILE | sed -r "s/(fec|forceencrypt)//g");;
    *verity*) KEEPVERITY=false; ZIPFILE=$(echo $ZIPFILE | sed "s/verity//g");;
    *quota*) KEEPQUOTA=false; ZIPFILE=$(echo $ZIPFILE | sed "s/quota//g");;
    *) break;;
  esac
done
IFS=$OIFS

check_data
get_flags
