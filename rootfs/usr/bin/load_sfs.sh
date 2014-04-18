#!/bin/bash
# James Budiono 2011-2012, 2013
# Licens: GNU GPL Version 3 or later
# Load / unload SFS on the fly - this is also the system SFS loader for Fatdog64
#
# note: uses bash - we don't need speed here, we need features (uses array etc)
# can probably be converted to ash but I can't be bothered
# version 2 - supports start/stop as a service (to be run from /etc/init.d)
#             When run in this way, supports persistence
# version 3 - proper recovery if we fail to load for whatever reason
# version 4 - canonicalise path if a parameter is passed in.
# version 5 - adapted to be the system SFS loader for Fatdog64, now lives in /sbin
# version 6 - more message, don't show base sfs
# version 7 - supports load/unload autorun script, unload from command line,
#             sfs will be loaded in order shown (previously in alphabetical order),
#             configuration override using /etc/load_sfs.conf
#
# Fatdog64 SFS structure (since 630 or version 7):
# ----
# In addition to standard structure, Fatdog64 SFS stores some metadata in
# /tmp/sfs. This metadata isn't normally visible as /tmp is usually 
# over-mounted and hidden by tmpfs. 
# The metadata is:
# a) /tmp/sfs/autorun.sh - this is the load/unload script. 
#    This script will be run when the SFS is loaded/unloaded, with these:
#    $1-event (load/unload/systemload/systemunload), $2-SFS aufs path.
#    Autorun can be disabled, see DISABLE_AUTORUN below.
# b) /tmp/sfs/msg - this is the message that will be displayed when the SFS
#    is loaded.
# 

# constants and start-up variables
MAXLOOP=250					# highest loop device number we can use
RESERVED=10					# reserve 10 loop devices for filemnt and others, can go higher but not lower than 10
SFS_DIR=/mnt/home			# where to look for sfs
BASE_SFS=alphat64-14.3.sfs	# don't show base sfs
UNLOAD_PERMANENTLY=false
LOAD_PERMANENTLY=false
LISTFILE=/etc/load_sfs
AUFS_ROOT=/aufs

# SFS metadata
SFS_DATA_ROOT=tmp/sfs # don't use absolute path
SFS_RUN_SCRIPT=$SFS_DATA_ROOT/autorun.sh
SFS_MSG=$SFS_DATA_ROOT/msg
DISABLE_AUTORUN= # make this non-blank to disable autorun

# config file to override all settings
[ -e /etc/load_sfs.conf ] && . /etc/load_sfs.conf
export SFS_DIR BASE_SFS LISTFILE

# boot-time configuration
#BOOTSTATE_PATH=/etc/BOOTSTATE
[ -e $BOOTSTATE_PATH ] && . $BOOTSTATE_PATH
[ "$BASE_SFS_PATH" ] && BASE_SFS=${BASE_SFS_PATH##*/}

# insertion point - below tmpfs, pup_save and pup_multi
INSERT_POINT=1	# tmpfs / pup_save
[ "$TMPFS_MOUNT" -a "$SAVEFILE_MOUNT" ] && INSERT_POINT=2   # both tmpfs & pup_save
[ "$MULTI_MOUNT" ] && INSERT_POINT=$(( $INSERT_POINT + 1 )) # pup_multi is another layer

########## core load/unload functions ###########

# $@ text to display
function message() {
	if [ "$DISPLAY" ]; then
		Xdialog --infobox "$@" 0 0 10000
	else
		echo -e "$@"
	fi
}

# output - FREELOOP = free loop device
function find_free_loop() {
	local loops_in_use
	for i in $(losetup -a | sed 's/:.*$//;s_/dev/loop__'); do
		loops_in_use[$i]=$i
	done
	#echo ${loops_in_use[@]}

	for ((i=$RESERVED; i<$MAXLOOP; i++)); do
		if [ -z "${loops_in_use[$i]}" ]; then
			break
		fi
	done
	#echo loop device $i is free	
	FREELOOP=$i
}

# $1 = loop device number
function check_and_make_loop_device() {
	if [ ! -b /dev/loop$1 ]; then
		mknod /dev/loop$1 b 7 $1
#	else
#		echo loop device $1 already exist
	fi
}

# $1 = pup_ro number
function check_and_make_pupro() {
	if [ ! -d $AUFS_ROOT/pup_ro$1 ]; then
		mkdir -p $AUFS_ROOT/pup_ro$1
#	else
#		echo pup_ro$1 already exist
	fi	
}

# $1 = path to SFS to load, $2 = system load
function sfs_load() {
	# make sure we're not loading the same sfs twice
	if [ -z "$(losetup -a | grep -F "${1##*/}")" ]; then
		# find free loop device, re-using what we can, if we can't, then make new loop/pup_ro mountpoint
		# keep loop-N and pup_ro-N sync at all times
		find_free_loop
		check_and_make_loop_device $FREELOOP
		check_and_make_pupro $FREELOOP
		
		# now ready to load
		if losetup /dev/loop$FREELOOP "$1"; then
			if mount -o ro /dev/loop$FREELOOP $AUFS_ROOT/pup_ro$FREELOOP; then
				if busybox mount -i -t aufs -o remount,ins:$INSERT_POINT:$AUFS_ROOT/pup_ro$FREELOOP=rr aufs /; then
					# run the run-script if it exists & allowed
					[ -z "$DISABLE_AUTORUN" -a -x $AUFS_ROOT/pup_ro$FREELOOP/$SFS_RUN_SCRIPT ] && 
					$AUFS_ROOT/pup_ro$FREELOOP/$SFS_RUN_SCRIPT ${2}load "$AUFS_ROOT/pup_ro$FREELOOP" # run load script
					[ -e $AUFS_ROOT/pup_ro$FREELOOP/$SFS_MSG ] && 
					message "$1 loaded successfully.\n $(<$AUFS_ROOT/pup_ro$FREELOOP/$SFS_MSG)" ||
					message "$1 loaded successfully."
					
					# menu refresh
					touch /usr/share/applications/abiword.desktop					
				else
					message "Failed to remount aufs $1" 
					umount -d $AUFS_ROOT/pup_ro$FREELOOP
				fi
			else
				message "Failed to mount branch for $1" 
				losetup -d /dev/loop$FREELOOP
			fi
		else
			message "Failed to assign loop devices loop$FREELOOP for $1" 
		fi
	fi	
}

# $1 = sfs-name to unload - we have to figure out which branch this is, $2=system unload
function sfs_unload() {
	# make sure the sfs we want to unload is loaded
	local loopdev=$(losetup -a | grep -F "$1" | sed '/loop[0-9]:/ d;s_\(/dev/loop[0-9]*\):.*_\1_')
	if [ -z $loopdev ]; then return; fi
	local branch=$(awk -v loop=$loopdev '$1==loop {print $2; exit}' /proc/mounts)
	
	if [ "$branch" ]; then
		# if allowed, run the run-script before unloading
		[ -z "$DISABLE_AUTORUN" -a -x $branch/$SFS_RUN_SCRIPT ] && 
		$branch/$SFS_RUN_SCRIPT ${2}unload "$branch" # run unload script

		# now ready to unload		
		busybox mount -i -t aufs -o remount,del:"$branch" unionfs / && 
		umount -d "$branch" &&
		message "$1 unloaded successfully." || message "Unable to unload $1"

		# menu refresh
		touch /usr/share/applications/abiword.desktop
	else
		losetup -d $loopdev # try to delete the loop anyway	
		message "$1 is not listed in aufs branch - cannot unload." 
	fi
}

############ persistence management  #############
# $1 = path to add
function add_to_list() {
	{ grep -Fv "$1" $LISTFILE; echo "$1"; } > $LISTFILE.tmp
	mv $LISTFILE.tmp $LISTFILE
}

# $1 = filename to remove
function remove_from_list() {
	grep -Fv "$1" $LISTFILE > $LISTFILE.tmp 2>/dev/null
	mv $LISTFILE.tmp $LISTFILE
}

# get all sfs from the list
function get_list() {
	cat $LISTFILE 2>/dev/null
}

############ GUI related stuff and helpers ############

function list_loaded_sfs() { 
	losetup -a | sed '/loop[0-9]:/ d;s_^.*/__;s/)$//'
}
#function list_loaded_sfs() {
#	while read p; do
#		echo ${p##*/}
#	done < $LISTFILE
#}
export -f list_loaded_sfs

# don't display already loaded sfs
function list_available_sfs() {
	ls $SFS_DIR 2> /dev/null | grep -Fi ".sfs" | grep -Fiv "$BASE_SFS" |  awk '
BEGIN {
	while ("list_loaded_sfs" | getline) {
		loaded[$0]=1
	}
}
{
	if (loaded[$0] == "") print $0
}
'
}
export -f list_available_sfs

function build_gui() {
export gui='
<window title="System SFS Loader">
	<vbox>
		<hbox>
			<frame Load SFS>
				<vbox>
					<tree>
						<variable>LOADSFS</variable>
						<label>Available SFS</label>
						<input>list_available_sfs</input>
						<height>200</height><width>300</width>
					</tree>
					<checkbox>
						<variable>LOAD_PERMANENTLY</variable>
						<label>Load at every boot</label>
						<default>'$LOAD_PERMANENTLY'</default>
					</checkbox>					
					<button>
						<label>Load</label>
					</button>
					<hbox>
						<entry accept="directory">
							<variable>SFS_DIR</variable>
							<input>echo $SFS_DIR</input>
						</entry>
						<button>
							<input file stock="gtk-open"></input>
							<action type="fileselect">SFS_DIR</action>
						</button>
						<button>
							<label>Refresh</label>
							<action type="refresh">LOADSFS</action>
						</button>					
					</hbox>					
				</vbox>
			</frame>		
			<frame Unload SFS>
				<vbox>
					<tree>
						<variable>UNLOADSFS</variable>
						<label>SFS currenty loaded</label>
						<input>list_loaded_sfs</input>
						<height>200</height><width>300</width>
					</tree>
					<checkbox>
						<variable>UNLOAD_PERMANENTLY</variable>
						<label>Do not load again at next boot</label>
						<default>'$UNLOAD_PERMANENTLY'</default>
					</checkbox>
					<button>
						<label>Unload</label>
					</button>
				</vbox>
			</frame>
		</hbox>
		<button>
			<label>Done</label>
			<action>exit:Done</action>
		</button>
	</vbox>
</window>
'
}

# gui for load/unload
function interactive() {
	while true; do
		build_gui
		OUTPUT=$(gtkdialog -cp gui)
		#echo $OUTPUT
		eval "$OUTPUT"
		case $EXIT in
			Load) 
				if [ "$LOADSFS" ]; then
					sfs_load "$SFS_DIR/$LOADSFS"
					if [ "$LOAD_PERMANENTLY" = "true" ]; then
						add_to_list "$SFS_DIR/$LOADSFS"
						message "$LOADSFS will be loaded at next boot".
					fi
				else
					message "You didn't choose anything to load. Please try again." 
				fi
				;;
				
			Unload) 
				if [ "$UNLOADSFS" ]; then
					sfs_unload "$UNLOADSFS"
					if [ "$UNLOAD_PERMANENTLY" = "true" ]; then
						remove_from_list "$UNLOADSFS"
						message "$UNLOADSFS will be no longer be loaded at next boot".
					fi					
				else
					message "You didn't choose anything to unload. Please try again." 
				fi
				;;
			Done|abort) 
				break 
				;;
		esac
	done
	return 0
}

############## main ##############
if [ -z "$1" ]; then
	# no parameter passed - use interactive gui
	[ $(id -u) -ne 0 -a "$DISPLAY" ] && exec gtksu "System SFS Loader" $0
	[ "$DISPLAY" ] && interactive || echo "Try ${0##*/} --help"
else
	case "$1" in
		start)
			#echo start service - loadall
			[ $(id -u) -ne 0 -a "$DISPLAY" ] && exec gtksu "System SFS Loader" $0 start
			[ $(id -u) -ne 0 -a -z "$DISPLAY" ] && exec su -c "$0 start"
			for a in $(get_list); do
				sfs_load "$a" system
				#echo $a
			done
			;;
		stop)
			#echo stop service - unloadall
			[ $(id -u) -ne 0 -a "$DISPLAY" ] && exec gtksu "System SFS Loader" $0 stop
			[ $(id -u) -ne 0 -a -z "$DISPLAY" ] && exec su -c "$0 stop"
			for a in $(get_list); do
				sfs_unload "${a##*/}" system
			done
			;;
		--help|-h|help)
			cat << EOF
Usage: $0 [start|stop|help|--help|-h|/path/to/sfsfile [load|unload|add|remove] ]

Without parameters, $0 will show the GUI.

$0 has a config file, located in $LISTFILE.
The config file stores the list of sfs to be automatically loaded or
unloaded by "start" and "stop" parameters below.
"Permanent" option in the GUI will update this config file.

With "start", it will load all the sfs found in the config file.
With "stop", it will unload all the sfs found in the config file.
"start" and "stop" is meant for when $0 is symlink-ed to 
/etc/init.d as system service.

Any other parameter will be taken as an SFS filename to load (or unload,
or added/removed from the list).
EOF
			;;
		*)
			# anything else - assume it's path to sfs to load 
			[ $(id -u) -ne 0 -a "$DISPLAY" ] && exec gtksu "System SFS Loader" $0 $(readlink -f "$1")
			[ $(id -u) -ne 0 -a -z "$DISPLAY" ] && exec su -c "$0 \"$(readlink -f "$1")\""
			case $2 in
				load|"") sfs_load $(readlink -f "$1") ;;
				unload) sfs_unload $(readlink -f "$1") ;;
				add) add_to_list $(readlink -f "$1"); message "$1" added. ;;
				remove) remove_from_list $(readlink -f "$1"); message "$1" removed ;;
			esac
			;;
	esac
fi
