#!/bin/bash
# fatdog-merge-layers.sh - merge one tmpfs layer to another, deleting the original
# Copyright (C) James Budiono 2011, 2012, 2013
# License: GNU GPL Version 3 or later
#
# This is based on snapmergepuppy s20, an independent re-implementation of a script of
# the same name from Puppy Linux.
#
# Change from s21 - remove dependency on lsof
# Change from s20 - closedfiles uses awk only, parameterised to merge any layers
# Change from s19 - adapted for Fatdog64 600 new layer structure
# Version s19 - last working copy available for standard puppies and Fatdog64 up to 521
#
# Note: supports aufs only
# Note: uses bash for its arrays
# Note: Since version 20, no attempt to stop/continue process (it crashes some apps)
#       (code to do that it still here, just commented out)
# Note: (obviously) assumes that both layers are r/w
#
# Call: $1 merge-from-layer, $2-merge-to-layer

# Don't use trailing slash here
TMPFS="$1"			# was /initrd/pup_rw
PUPSAVE="$2"		# was /initrd/pup_ro1
DISKFULL=/tmp/diskfull
LANG=C 				# make bash run

# only merge when both layers exist
! [ "$TMPFS" -a "$PUPSAVE" ] && exit 

# print list of all closed files in TMPFS (originally from closedfiles.awk)
function closedfiles() {
	# use awk for this - much faster than bash
	TMPFILE=$(mktemp)
	cat >> $TMPFILE <<EOF
#!/bin/awk -f
# jamesbond 2011 - print list of files in TMPFS which is closed
BEGIN {
	# load our "list of open files" before processing - assume they all are in $TMPFS
	while ("find /proc -type l -wholename \"/proc/*/fd/*\" 2>/dev/null | xargs ls -l 2>/dev/null | sed 's/.*-> //; /^socket:/d; /^pipe:/d; /^anon_inode:/d' | sort | uniq" | getline) {
		openfiles["$TMPFS" \$0]=1
	}
	
	# now compare this with the list of files in $TMPFS
	CMDLINE = "find \"$TMPFS\" -not -type d"
	while (CMDLINE | getline) {
		if (openfiles[\$0] != 1) print \$0;
	}
}
EOF
	chmod +x $TMPFILE
	$TMPFILE
	rm -f $TMPFILE
}

# diropq sometimes not working. 
# to test: create a test in pupsave and see if it's visible from rootfs
# $1 = dir base (rootfs)
# $2 = pupsave dir base
function test_diropq() {
	local WORKING=0
	local TMPFILE=$(mktemp "$2"/diropqtest.XXXXXXXXX)
	[ -e "$1/${TMPFILE##*/}" ] && WORKING=1
	rm -rf $TMPFILE
	#echo $1 $WORKING
	return $WORKING;
}

# the actual snapmerge function - from s14_helper
function do_snapmerge() {
	# check for new whiteouts - if yes remove files from pupsave
	echo "deleting newly deleted files"
	find "$TMPFS" -mount \( -regex '.*/\.wh\.[^/]*' -type f \) | 
	grep -v -E ".wh..wh.orph|.wh..wh.plnk|.wh..wh.aufs" |
	while read -r FILE; do
		#echo $FILE					# $FILE is TMPFS_WHITEOUT
		FULLNAME="${FILE#$TMPFS}"
		#echo $FULLNAME
		BASE="${FULLNAME%/*}"
		#echo $BASE
		LEAF="${FULLNAME##*/}"
		#echo $LEAF
		#echo $BASE/$LEAF
		
		PUPSAVE_FILE="${PUPSAVE}${BASE}/${LEAF:4}"	
		#echo "Deleting $PUPSAVE_FILE"
		rm -rf "$PUPSAVE_FILE"		# delete the file/dir if it's there
		
		# if this is a dir-opaque file, we need to remove the dir in pupsave
		# but only if the dir-opaque is currently working !!
		if [ "$LEAF" = ".wh..wh..opq" ] && test_diropq "${BASE}" "${PUPSAVE}${BASE}"; then
			#echo remove "${PUPSAVE}${BASE}"
			rm -rf "${PUPSAVE}${BASE}"
		fi
	done

	# check for old whiteouts - remove them from pupsave if new files created in tmpfs
	echo "deleting old whiteouts"
	find "$PUPSAVE" -mount \( -regex '.*/\.wh\.[^/]*' -type f \) | 
	grep -v -E ".wh..wh.orph|.wh..wh.plnk|.wh..wh.aufs|.wh..wh..opq" |
	while read -r FILE; do
		#echo $FILE					# $FILE is PUPSAVE_WHITEOUT
		FULLNAME="${FILE#$PUPSAVE}"
		#echo $FULLNAME
		BASE="${FULLNAME%/*}"
		#echo $BASE
		LEAF="${FULLNAME##*/}"
		#echo $LEAF
		#echo $BASE/$LEAF
		
		TMPFS_FILE="${TMPFS}${BASE}/${LEAF:4}"
		#echo $TMPFS_FILE

		# delete whiteout only if a new file/dir has been created in the tmpfs layer
		if [ -e "$TMPFS_FILE" -o -L "$TMPFS_FILE" ]; then
			# if TMPFS_FILE is a dir, we need to add diropq when removing its pupsave whiteout
			# this is just in case and it won't work until next reboot anyway
			[ -d "$TMPFS_FILE" ] &&	touch "$TMPFS_FILE/.wh..wh..opq"
			#echo Deleting whiteout $FILE
			rm -f "$FILE"
		fi
	done

	# by now we should be consistent - so rsync everything
	echo "rsync-ing"
	rm -rf $DISKFULL
	if ! rsync --inplace -a --force "$TMPFS"/ "$PUPSAVE"; then
		case $(df | grep "$PUPSAVE" | awk '{print $4}') in 
			0|"") touch $DISKFULL ;;
		esac
	fi
}

# cleanup - delete files from tmpfs, but only if disk is not full
function do_cleanup() {
	if [ ! -f $DISKFULL ] > /dev/null; then
		closedfiles |
		grep -v -E ".wh..wh.orph|.wh..wh.plnk|.wh..wh.aufs|.wh..wh..opq" | tee /tmp/filesmoved.txt |
		xargs rm -rf
	fi	
}

# freeze all process excluding ourself
function freeze_processes() {
	echo "Freezing all processes"
	allprocess=($(ps -eo pid,ppid))
	i=2; j=0;
	while [ $i -lt  ${#allprocess[@]} ]; do
		if  ((	allprocess[i] != $$ && \
				allprocess[i] > 1 && \
				allprocess[$((i+1))] > 1 )); then
					#echo ${allprocess[$i]} ${allprocess[$(($i+1))]}
					frozen[$((j++))]=${allprocess[$i]}
					kill -STOP ${allprocess[$i]}
		fi
		i=$(($i+2))
	done
	echo "All process now frozen"
}

# wake them up again
function thaw_processes() {
	for i in ${frozen[@]}; do
		#echo $i
		kill -CONT $i
	done
	echo "All processes now thawed"
}

# force re-evalution of all the layers
function aufs_reval() {
	busybox mount -t aufs -o remount,udba=reval aufs /
}

function warn_user() {
	# if tmpfs larger than 32MB, warn user save file may be slow
	TMPFS_SIZE=$(du -sb "$TMPFS" | cut -f 1)
	TMPFS_FILES=$(ls -aR "$TMPFS" | wc -l)
	if (( TMPFS_SIZE > 64*2**20 || TMPFS_FILES > 1000 )); then
		Xdialog --msgbox "You have $TMPFS_FILES files and $((TMPFS_SIZE/2**20))MB worth of data unsaved in RAM.\n \
Merging process may be slow, the computer will appear to freeze during saving.\n \
Please be patient and don't shutdown your computer. \n \
\n \
If you need to do something before this happens, please do it now.\n \
Press OK when you're ready." 0 0 10000
	fi
}

################### main ######################
# originally from s14.awk
# make us run with highest priority (we promise we'll be quick)
renice -n -20 $$

# freeze all process excluding ourself
# warn_user				# warn before freezing if tmpfs is huge and will take long time
# freeze_processes

# do the job
do_snapmerge
do_cleanup

# wake them up again
# thaw_processes

# force re-evalution of all the layers
aufs_reval

# warn diskfull is necessary
if [ -f $DISKFULL ]; then
	[ "$DISPLAY" ] && Xdialog --infobox "Your save file is full, please copy important items manually elsewhere." 0 0 10000	||
					  echo "Your save file is full, please copy important items manually elsewhere."
fi
