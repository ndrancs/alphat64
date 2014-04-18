#!/bin/dash
# freemem.sh, replacement for freememappletd
# display an icon on icon try showing how much space is left on savefile
# (C) James Budiono 2013
# License: GPL Version 3 or later
#
# uses 'sit' (simple-icon-tray) from technosaurus
# all the logic in calcfreespace.sh is here too
#

### configuration
PERIOD=15	# period (in seconds) to check 
FONT_SIZE='24'
FONT_FAMILY='Sans'
NORMAL_BG_COLOR='none' 
NORMAL_TEXT_COLOR='white'
ALERT_BG_COLOR='red'
ALERT_TEXT_COLOR='white'

LOW_TMPFS_THRESHOLD=5120	# 5 MB (in kb) - limit to trigger snapmerge
LOW_SAVE_THRESHOLD=10240	# 10 MB (in kb) - limit to trigger visual warning
LOW_MEM_WARNING="WARNING: Personal storage getting full, strongly recommend you resize it or delete files!"

F_SNAPMERGE_REQUEST=/tmp/snapmergepuppy.request	# with 20-ram-save service
FREEMEM_DIR=/tmp/freememapplet.$USER.$XSESSION_ID
FREEMEM_ICON=$FREEMEM_DIR/icon.svg
FREEMEM_TOOLTIP=$FREEMEM_DIR/tooltip

# external configuration
EVENTMANAGER_CONFIG=/etc/eventmanager
RAMSAVEINTERVAL=0 # overridden by eventmanager
. $BOOTSTATE_PATH # TMPFS_MOUNT, SAVEFILE_MOUNT
[ -e $EVENTMANAGER_CONFIG ] && . $EVENTMANAGER_CONFIG # RAMSAVEINTERVAL

################## helper ####################
# check remaining free space, warn and snapmerge if low, update icon
# $1 - mountpoint to monitor
monitor_free_space() {
	local freespace text text_color bg_color
	
	# get the remaining free space on monitored mountpoint
	freespace=$(df -k "$1" | awk 'NR==2 {print $4}') # for measuring low space conditions
	text=$(df -h "$1" | awk 'NR==2 {print $4}') # for display
	text_color=$NORMAL_TEXT_COLOR
	bg_color=$NORMAL_BG_COLOR
	
	# if we're on RAM layer, and allowed to snapmerge, and low on space, then we request snapmerge
	if [ -n "$TMPFS_MOUNT" -a -n "$SAVEFILE_MOUNT" -a $RAMSAVEINTERVAL -ne 0 -a $freespace -lt $LOW_TMPFS_THRESHOLD ]; then
		touch $F_SNAPMERGE_REQUEST
	fi
		
	# visual warning when low
	if [ $freespace -lt $LOW_SAVE_THRESHOLD ];then
		killall yaf-splash
		yaf-splash -margin 2 -bg red -bw 0 -placement top -font "9x15B" -outline 0 -text "$LOW_MEM_WARNING" &
		text_color=$ALERT_TEXT_COLOR
		bg_color=$ALERT_BG_COLOR
	fi
	
	# update icon and tooltip
	cat > $FREEMEM_ICON << EOF
<svg version="1.1" viewBox="0 0 64 64" preserveAspectRatio="xMinYMin meet">
<rect width="100%" height="100%" stroke="none" fill="$bg_color" />
<text text-anchor="middle" x="32" y="40" font-family="$FONT_FAMILY" font-size="$FONT_SIZE" fill="$text_color">$text</text>
</svg>
EOF
	{ 
		echo "Free disk space in your savefile: $text"
		echo -n "Right-click to launch disk-usage analyser."
	} > $FREEMEM_TOOLTIP	
}

########## main ###########
# prepare
mkdir -p $FREEMEM_DIR
touch $FREEMEM_ICON $FREEMEM_TOOLTIP

# launch sit and set trap handler
sit $FREEMEM_ICON $FREEMEM_TOOLTIP "" "gdmap -f /" &
XPID=$!
trap 'kill $XPID; rm -rf $FREEMEM_DIR; exit' INT TERM # kill sit when we die

# decide which mountpoint to monitor
if [ $SAVEFILE_MOUNT ]; then
	MONITOR=$SAVEFILE_MOUNT
elif [ $TMPFS_MOUNT ]; then
	MONITOR=$TMPFS_MOUNT
else
	MONITOR=/
fi

# start monitoring 
while :; do
	monitor_free_space $MONITOR
	sleep $PERIOD
	! kill -0 $XPID 2> /dev/null && exit # if sit died, we exit too
done
rm -rf $FREEMEM_DIR
