#!/bin/ash
# shared multisession-save library for rc.shutdown and savesession-dvd
# Copyright (C) James Budiono 2012
# License: GNU GPL Version 3 or later
#
# Version 1.1 - with options to use from a running session, not only shutdown
# Version 1.0 - was in Fatdog 600, in rc.shutdown
#
# Note: this will not work on its own, it must be sourced.

##################### savefile utilities ########################
### mount device to temporary mount point
# will use existing mountpoint if device is already mounted
# $1-device (with /dev prefix), returns mountpoint (empty if error)
mount_device() {
	local tmpdir dmdev
	dmdev=$(ls -l /dev/mapper 2> /dev/null | awk -v dmdev=${1##*-} '$1 != "total" && $6 == dmdev {print "/dev/mapper/" $10; exit; }')
	if grep -Eqm 1 "^$1 |^$dmdev " /proc/mounts; then
		awk -v dev=$1 -v dmdev=$dmdev '$1 == dev || $1 == dmdev { print $2; exit; }' /proc/mounts	
	else
		tmpdir=$(mktemp -dp /tmp shutdown-mnt-XXXXXX)
		! case $(guess_fstype $1) in 
			ntfs) ntfs-3g $1 $tmpdir ;;
			vfat) mount -o utf8 $1 $tmpdir ;;
			*) mount $1 $tmpdir ;;
		esac > /dev/null && tmpdir=
		echo $tmpdir
	fi
}

### save in multisession mode
# MULTI_MOUNT, MULTI_DEVICE, SAVEFILE_MOUNT, SAVEFILE_PATH, SAVEFILE_PROTO, MULTI_PREFIX
# $1 - "shutdown" or "noshutdown" - shutdown means do extreme measure to save, MULTI_MOUNT will be gone after running this
#
save_multisession() {
	GROWISOFS="growisofs -M /dev/$MULTI_DEVICE -iso-level 4 -D -R" # options must be identical with build-iso and remaster
	
	# 0. Lock session
	[ -z $MULTI_MOUNT ] && return		# can only do this when we're in multisession mode	
	[ "$1" != "shutdown" -a -d $MULTI_SAVE_DIR ] && return	# existing save in progress, abort
	mkdir -p $MULTI_SAVE_DIR
		
	# 1. get savefile base name (savefilebase) and path (savepath)
	#    - path used for grafting (if there is none, graft at root directory)
	#    - basename used to construct complete savefilename based on $MULTI_PREFIX, timestamp and .sfs
	savefilebase="$SAVEFILE_PROTO" && [ "$SAVEFILE_PATH" ] && savefilebase=$SAVEFILE_PATH
	savepath="${savefilebase%/*}/" && [ "${savepath}" = "${savefilebase}/" ] && savepath=/
	savefilebase=${savefilebase##*/}; savefilebase=${MULTI_PREFIX}${savefilebase%.*} 
	
	# 2. build the savefile name (basename + timestamp + .sfs) 
	savefileproto=${savepath}${savefilebase}
	timestamp=$(date -Iminutes | tr : -)
	savefile="$savefileproto-$timestamp-save.sfs"
	basefile="$savefileproto-$timestamp-base.sfs" # so that it is loaded first	
	archivepath="archive/$timestamp"
	
	# 3. save "archive" files first if archive is not empty, do it here to make room for mksquashfs
	if [ $(find "$SAVEFILE_MOUNT"/archive -maxdepth 0 -type d \! -empty) ]; then
		save_ok=yes
		echo -n "Saving archives to $archivepath... "
		if cat /proc/sys/dev/cdrom/info | grep "drive name" | grep -q $MULTI_DEVICE; then
			# cdrom - assume dvd, use growisofs
			! $GROWISOFS -root $archivepath "$SAVEFILE_MOUNT"/archive/* >> /dev/initrd.err 2>&1 && save_ok=no		
		else
			# else assume harddisk - copy
			tmpdir=$(mount_device /dev/$MULTI_DEVICE)
			if [ "$tmpdir" ]; then
				mkdir -p "$tmpdir/$savepath/$archivepath"
				! cp -a "$SAVEFILE_MOUNT"/archive/* "$tmpdir/$savepath/$archivepath" && save_ok=no
				umount $tmpdir
			else
				save_ok=no
			fi
		fi
		# result
		case $save_ok in 
			yes) echo "done." ;;
			no) echo "failed." ;; #TODO: error handling
		esac
		rm -rf "$SAVEFILE_MOUNT"/archive/*	# keep the original archive folder, we need it
	fi
		
	# 4. see if the disk is empty (no previous sessions), if yes, save old files as initial session
	tmpdir=$(mount_device /dev/$MULTI_DEVICE)
	if ! ls $tmpdir/$savefileproto* > /dev/null 2>&1; then
		echo "Creating initial session $basefile..."
		mksquashfs "$MULTI_MOUNT" "$MULTI_SAVE_DIR/$basefile" -comp xz > /dev/null
	fi
	umount $tmpdir
	
	# 5. build the session file (mksquashfs)
	echo -n "Saving session to $savefile... "
	# delete old files to free up space for new ones - only during shutdown
	[ "$1" = "shutdown" ] && find "$MULTI_MOUNT" -xdev \! \( -path "${MULTI_MOUNT}${AUFS_ROOT}*" -o -path "$MULTI_MOUNT" \) -delete 
	mkdir -p $MULTI_SAVE_DIR	# in case aufs bug, needs to do it again here	
	mksquashfs "$SAVEFILE_MOUNT" "$MULTI_SAVE_DIR/$savefile" -comp xz > /dev/null
	
	# 6. and "burn" it
	save_ok=yes
	if cat /proc/sys/dev/cdrom/info | grep "drive name" | grep -q $MULTI_DEVICE; then
		# 6.1 cdrom device, assume DVD, so use growisofs
		umount /dev/$MULTI_DEVICE
		! $GROWISOFS -root "$savepath" $MULTI_SAVE_DIR/* >> /dev/initrd.err 2>&1 && save_ok=no
		[ "$1" = "shutdown" ] && cdrom_id --eject-media /dev/$MULTI_DEVICE > /dev/null	# eject media when done
	else
		# 6.2 not cdrom, assume harddisk, so copy it
		tmpdir=$(mount_device /dev/$MULTI_DEVICE)
		if [ "$tmpdir" ]; then
			mkdir -p "$tmpdir/$savepath"
			! cp $MULTI_SAVE_DIR/* "$tmpdir/$savepath" && save_ok=no
			umount $tmpdir
		else
			save_ok=no
		fi
	fi
	
	# 7. results
	case $save_ok in 
		yes) echo "done." ;;
		no) echo "failed." ;; #TODO: error handling
	esac
	
	# 8. merge down so that next time the same info is not saved again - only for non-shutdown event
	[ "$1" != "shutdown" ] && fatdog-merge-layers.sh "$SAVEFILE_MOUNT" "$MULTI_MOUNT"
	
	# 9. unlock session and reclaim space
	rm -rf $MULTI_SAVE_DIR
}
