#!/bin/ash
# calcfreespace.sh is called by freememappletd, by default every 15 seconds.
# (C) James Budiono 2012, 2013
# License: GNU GPL Version 3 or later
# 
# Jan 2013 - use stat not df
#

### configuration
EVENTMANAGER_CONFIG=/etc/eventmanager
LOW_TMPFS_THRESHOLD=5120	# 5 MB (in kb)
LOW_SAVE_THRESHOLD=10240	# 10 MB (in kb)
LOW_MEM_WARNING="WARNING: Personal storage getting full, strongly recommend you resize it or delete files!"
F_SNAPMERGE_REQUEST=/tmp/snapmergepuppy.request	# with 20-ram-save service

# load configuration
. $BOOTSTATE_PATH		# boot-time configuration
. $EVENTMANAGER_CONFIG	# RAMSAVEINTERVAL 

################## helper ####################
# returns $freespace
calc_free_space() { 
	freespace=$(dc $(stat -f -c "%a %S" /) '*' 1024 / p)

	# if we're using RAM layer, and allowed to do snapmerge, and freespace is less than tmpfs threshold, then request snapmerge
	[ "$TMPFS_MOUNT" -a "$SAVEFILE_MOUNT" -a $RAMSAVEINTERVAL -ne 0 -a $freespace -lt $LOW_TMPFS_THRESHOLD ] && touch $F_SNAPMERGE_REQUEST
		
	# warn
	if [ $freespace -lt $LOW_SAVE_THRESHOLD ];then
		killall yaf-splash
		yaf-splash -margin 2 -bg red -bw 0 -placement top -font "9x15B" -outline 0 -text "$LOW_MEM_WARNING" &
	fi		
}

################## main ####################
calc_free_space > /dev/null
echo $freespace # display the result
