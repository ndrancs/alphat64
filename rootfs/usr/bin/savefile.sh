#!/bin/sh
# Shutdown dialog 
# Copyright (C) James Budiono 2012
# License: GNU GPL Version 3 or later
#
# 1.0 - initial release
#
# What it does: create savefile, set new hostname
# Called by rc.shutdown

### configuration variables
APPTITLE="Create Save File"
ENCTYPE=aes
DOWNLOAD_FOLDER=/root/spot/Downloads 
SAVEFILE_PROTO=/alphat64save.ext4	# overriden by BOOTSTATE
. $BOOTSTATE_PATH					# BOOTSTATE_PATH exported by rc.shutdown
[ "$SAVEFILE_MOUNT" ] && exit		# already have a savefile

### runtime variables
step=1						# current wizard step
savedevice=					# chosen save device (cannot be empty)
savedevicetype=				# filesystem type of the save device
savefile=${SAVEFILE_PROTO##*/}	# chosen savefile name and path (cannot be empty)
savepath=					# path component of savefile, calculated from savefile
savesize=512				# chosen size of savefile, in MB (cannot be empty)
savefs=						# chosen filesystem of savefile (cannot be empty)
encrypted=					# chosen encryption type - none, dmcrypt, or cryptoloop
savepassword=				# chosen password for encryption (cannot be empty)
savefile_mount=				# temporary mount point for savefile
movedownload=on				# whether we move download folder
savedownload=				# the symlink to the new download folder
hostname=$(hostname)		# new hostname
rootpassword=woofwoof		# new root password
savetype=file				# file or dir
savedir=/${savefile%.ext4}	# savedir

### step movements
go_step() { step=$1; }
go_next() { step=$((step + 1)); }
go_prev() { step=$((step - 1)); }
go_exit() { step=exit; }

prev_action=
prev_step=
next_wizard_step() {
	local action=$?
	[ "$1" ] && action=$1
	prev_step=$step
	case $action in
		0) go_next ;;				# Xdialog ok
		3) go_prev ;;				# Xdialog previous
		1|255) go_step warning ;;	# Xdialog Esc/window kill
	esac
	prev_action=$action
}


### actual steps here
introduction() {
	local msg=$(cat << EOF
You are running in RAM. At this moment, none of your data in this session is saved.	

If you want to save your data, you need to create a savefile. Do you want to create a savefile now?
EOF
)
	Xdialog --fill --title "$APPTITLE" --yesno "$msg" 0 0
	next_wizard_step
}

### warn we are about to exit without creating savefile
data_loss_warning() {
	local msg=$(cat <<EOF
You click "Cancel" during the savefile creation process. If you cancel this process, none of your data in this session will be saved.

Are you sure you want to stop this process, and lose all your data in this session?
EOF
)
	if Xdialog --fill --title "$APPTITLE" --yesno "$msg" 0 0; then go_exit
	else go_step $prev_step
	fi
}

### get the device / partition to save
choose_device() {
	local msg="Choose the device/partition to save to."
	local items=$(list_devices)
	savedevice=$(eval "Xdialog --title \"$APPTITLE\" --wizard --no-tags --stdout --check \"Save as multisession\" --radiolist \"$msg\" 20 80 5 $items")
	next_wizard_step
	set -- $savedevice
	savedevice=$1
	[ "$2" = "checked" ] && go_step multisession-confirm
}
list_devices() {
	local FS_TYPE label size
	while read p; do
		FS_TYPE=$(guess_fstype /dev/$p)
		case "$FS_TYPE" in
			unknown|""|swap)  case $p in sr*) echo -n "/dev/$p \"/dev/$p $(cat /sys/block/$p/device/model)\" off " ;; esac ;;
			*)  #label=$(disktype /dev/$p | sed -n '/Volume name/ { s/.*"\(.*\)".*/\1/; p}')
				label=$(busybox blkid /dev/$p | sed -n "\_^/dev/${p}:_ {"'/LABEL/ {s/.*LABEL="\([^"]*\)".*/\1/; p}}')
				size=$(( $(cat /sys/class/block/$p/size) / 2048 )) # each block is 512-byte, convert to MB
				echo -n "/dev/$p \"/dev/$p ($label) type $FS_TYPE size $size MB\" off " ;;
		esac
	done << EOF
$(ls /sys/class/block | grep -vE "^loop|^ram|^nbd" | sort -V)
EOF
}

### get the savetype
choose_savetype() {
	local choice
	case $(guess_fstype $savedevice) in
		ext*) 
			choice=$(Xdialog --title "$APPTITLE" --wizard --stdout --no-tags \
			--radiolist "How do you want to save your session?" 0 0 0 \
			file "Use a savefile" $([ "$savetype" = file ] && echo on || echo off) \
			dir "Save in a directory" $([ "$savetype" = dir ] && echo on || echo off))
			next_wizard_step
			[ "$choice" ] && savetype=$choice
			[ $prev_action -eq 0 -a "$savetype" = dir ] && go_step 50
			;;
		*) next_wizard_step $prev_action ;;
	esac	
}

### get the size and filename
choose_size_and_name() {
	local sizeinfo msg1 msg2 msg3 msg4 choice tmpmount minsize
	savedevicetype=$(guess_fstype $savedevice)

	# try mounting, also to get the free space
	tmpmount=""
	dmdev=$(ls -l /dev/mapper 2> /dev/null | awk -v dmdev=${savedevice##*-} '$1 != "total" && $6 == dmdev {print "/dev/mapper/" $10; exit; }')
	if ! grep -Eqm 1 "^$savedevice |^$dmdev " /proc/mounts; then
		tmpmount=$(mktemp -dp /tmp)
		if ! case $type in
			ntfs) ntfs-3g $savedevice $tmpmount	;;
			vfat) mount -o utf8 $savedevice $tmpmount ;;
			*) mount $savedevice $tmpmount ;;
		esac; then
			# failed to mount
			msg1="Problem: Unable to access $savedevice. Please choose another device/partition."
			Xdialog --title "$APPTITLE" --msgbox "$msg1" 0 0
			go_prev
			
			rmdir $tmpmount		
			return
		fi
	fi
	sizeinfo=$(df -h | grep $savedevice | awk '{print $2, " disk and has ", $4, "free space."; exit}')
	minsize=$(du -sm "$TMPFS_MOUNT" | awk '{print $1}') 
	[ $tmpmount ] && umount $tmpmount && rmdir $tmpmount	
	
	msg1="$savedevice is a $sizeinfo"
	msg2="How large do you want your savefile? (in MB).\nYou need at least $minsize MB to save your current session."
	msg3="Specify the path and filename of the savefile (if in doubt, don't change)"
	msg4="Yes! I want to move Downloads folder to $savedevice too\nso it won't take up space in the savefile."
	
	if choice=$(Xdialog --title "$APPTITLE" --wizard --stdout --separator : --check "$msg4" $movedownload --2inputsbox "$msg1" 0 0 "$msg2" "$savesize" "$msg3" "$savefile"); then
		next_wizard_step
		set -- $choice
		savesize=${1%%:*}
		savefile=${1#*:}
		savepath=${savefile%/*}; [ "$savepath" = "$savefile" ] && savepath= # special case
		
		movedownload=on
		savedownload=$SAVE_DEV_PROTO/$savepath/${DOWNLOAD_FOLDER##*/}
		[ "$2" = "unchecked" ] && movedownload= && savedownload=
		
		# check that specified size must be more than current session size.
		if [ $savesize -lt $minsize ]; then
			Xdialog --title "$APPTITLE" --infobox "The specified size ($savesize MB) is less than the current session size ($minsize MB)." 0 0 10000
			go_prev 
		fi 
	else
		next_wizard_step	
	fi
}

### get filesystem type for savefile & whether encryption is used
choose_fs_and_encryption() {
	local choice msg1 msg2 items encstate
	msg1="Choose the filesystem you want to use for the savefile."
	msg2="Tick the box if you want to encrypt savefile."
	items=$(cat << EOF
ext4 "Ext4 - efficient for large savefile" off \
ext3 "Ext3 - resilient against crash" off \
ext2 "Ext2 - traditionally used for encrypted savefile" off
EOF
)
	[ "$encrypted" -a "$encrypted" != "none" ] && encstate=on
	if choice=$(eval "Xdialog --title \"$APPTITLE\" --wizard --stdout --no-tags --check \"$msg2\" \"$encstate\" --radiolist \"$msg1\" 0 0 0 $items"); then
		next_wizard_step
		set -- $choice; savefs=$1
		case $2 in
			checked)
				# if encrypted, add _crypt_ to savefile
				case $savefile in
					*_dmcrypt_*) encrypted=dmcrypt ;; 
					*_crypt_*)   encrypted=cryptoloop; savefs=ext2 ;;	# cryptoloop requires ext2
					*)	msg1=${savefile%%.*}; msg2=${savefile#*.}
						savefile=${msg1}_dmcrypt_.${msg2}	
						encrypted=dmcrypt 	# use _dmcrypt_ by default now 
						;;
				esac
				;;
			
			unchecked)
				# not encrypted, make sure filename doesn't contain _crypt_
				encrypted=none
				case $savefile in
					*_crypt_*)
						msg1=${savefile%%_crypt_*}; msg2=${savefile#*_crypt_}
						savefile=$msg1$msg2 
						;;
					*_dmcrypt_*)
						msg1=${savefile%%_dmcrypt_*}; msg2=${savefile#*_dmcrypt_}
						savefile=$msg1$msg2
						;;
				esac
				;;
		esac
	else
		next_wizard_step
	fi	
}

### get the password for encryption - if we use encryption
choose_password() {
	local msg msg1 msg2 choice
	case $encrypted in 
		none)
			next_wizard_step $prev_action
			;;
		*)
			while true; do
				msg="Please type in the password for your savefile. Password cannot contain spaces."
				msg1="Type your password."
				msg2="Type your password again - make sure it matches with the above."
				if choice=$(Xdialog --title "$APPTITLE" --backtitle "Savefile Password" --wizard --stdout --separator " " --password --password --2inputsbox "$msg" 0 0 "$msg1" "$savepassword" "$msg2" "$savepassword"); then
					# next action - must check password
					set -- $choice
					[ "$1" ] && [ "$1" = "$2" ] && savepassword="$1" && go_next && break

					msg="Problem: Passwords do not match. For your own safety, please re-type the passswords again."
					[ -z "$1" ] && msg="Problem: When using encryption, password cannot be blank."
					Xdialog --title "$APPTITLE" --backtitle "Savefile Password" --msgbox "$msg" 0 0
				else
					next_wizard_step
					break;
				fi
			done
			;;
	esac
}

### get a new hostname
choose_hostname() {
	local msg choice

	while true; do
		msg=$(cat <<EOF
The hostname is your computer's name on the network. \
The current hostname is chosen randomly during system start-up. \
You can change that, or just click OK to keep it.

Hostname should be unique across your entire network.
EOF
)
		if choice=$(Xdialog --fill --title "$APPTITLE" --backtitle "Set Hostname" --wizard --stdout --inputbox "$msg" 0 0 "$hostname"); then
			# next action - must check hostname is not blank
			[ "$choice" ] && hostname=$choice && go_next && break;

			msg="Problem: Hostname cannot be blank."
			Xdialog --title "$APPTITLE" --backtitle "Set Hostname" --msgbox "$msg" 0 0
		else
			next_wizard_step
			break
		fi
	done
}

### change root password
change_root_password() {
	local msg msg1 msg2 choice
	
	while true; do
		msg="Password for root user is currently set to \"$rootpassword\".\nYou can change that, or just click OK to keep it."
		msg1="Type your password. Password cannot contain spaces or colons."
		msg2="Type your password again - make sure it matches with the above."
		if choice=$(Xdialog --title "$APPTITLE" --backtitle "Set Root Password" --wizard --stdout --separator " " --password --password --2inputsbox "$msg" 0 0 "$msg1" "$rootpassword" "$msg2" "$rootpassword"); then
			# next action - must check password
			set -- $choice
			[ "$1" ] && [ "$1" = "$2" ] && rootpassword="$1" && go_next && break

			msg="Problem: Passwords do not match. For your own safety, please re-type the passswords again."
			[ -z "$1" ] && msg="Problem: root password cannot be blank."
			Xdialog --title "$APPTITLE" --backtitle "Set Root Password" --msgbox "$msg" 0 0
		else
			next_wizard_step
			break;
		fi
	done
}


### confirm all the selected parameter
confirmation() {
	local msg 

	msg=$(cat <<EOF
You have chosen to create a savefile as follows:

- Savefile location : $savedevice
- Path and filename : $savefile
- Size of savefile : $savesize MB
- Filesystem : $savefs
- Encryption : $encrypted $([ "$encrypted" -a "$encrypted" != "none" ] && echo with password: $savepassword) 
- New hostname: $hostname
- New root password: $rootpassword
$([ $movedownload ] && echo - Move Downloads folder to $savedevice)

Make sure you get everything correct.
If you click "Next", the savefile will be created and the hostname will be set.
If some of the above are wrong, click "Previous" now and correct them.
EOF
)
	Xdialog --left --title "$APPTITLE" --backtitle "Confirm Selected Settings" --wizard --yesno "$msg" 0 0
	next_wizard_step
}


### create the savefile - do the heavylifting here
create_savefile() {
	local msg xpid tmpmount devloop
	
	# tell user it will take a while
	msg="Creating savefile $savefile on $savedevice, please wait ..."
	Xdialog --title "$APPTITLE" --no-buttons --infobox "$msg" 0 0 3600000 & # one hour
	xpid=$!
	
	# check if it's already mounted. If it does, use existing mount point
	dmdev=$(ls -l /dev/mapper 2> /dev/null | awk -v dmdev=${savedevice##*-} '$1 != "total" && $6 == dmdev {print "/dev/mapper/" $10; exit; }')	
	tmpmount=$(awk -v dev=$savedevice -v dmdev=$dmdev '$1 == dev || $1 == dmdev { print $2; exit; }' /proc/mounts)
	if [ -z "$tmpmount" ]; then	
		tmpmount=$(mktemp -dp /tmp devsave.XXXXXX)
		if ! case $savedevicetype in
			ntfs) ntfs-3g $savedevice $tmpmount	;;
			*) mount $savedevice $tmpmount ;;
		esac; then
			# failed to mount
			kill $xpid
			msg="Problem: Unable to access $savedevice, please choose another device/partition."		
			Xdialog --title "$APPTITLE" --msgbox "$msg" 0 0
			go_step 2
			
			rmdir $tmpmount	
			return
		fi
	fi
		
	# check whether a savefile with that name already exist
	if [ -e $tmpmount/$savefile ]; then
		kill $xpid
		msg="Problem: $savefile on $savedevice already exist. Please choose a different name."
		Xdialog --title "$APPTITLE" --msgbox "$msg" 0 0 
		go_step 3
		
		umount $tmpmount && rmdir $tmpmount			
		return	
	fi
	
	# create the savefile
	[ "$savepath" ] && mkdir -p $tmpmount/$savepath
	if ! dd if=/dev/zero of=$tmpmount/$savefile count=0 bs=1 seek=${savesize}M; then
		kill $xpid	
		msg="Problem: Unable to create $savefile on $savedevice. Please choose another device/partition."	
		Xdialog --title "$APPTITLE" --msgbox "$msg" 0 0 
		go_step 2
		
		umount $tmpmount && rmdir $tmpmount
		return
	fi
	
	# make filesystem on the savefile - from here assume everything is successful
	savefile_mount=$(mktemp -dp /tmp pupsave.XXXXXX)
	case $encrypted in 
		none)
			mke2fs -F -m 0 -t $savefs $tmpmount/$savefile
			mount -o loop $tmpmount/$savefile $savefile_mount
			;;	
			
		dmcrypt)	
			count=0; while [ -e /dev/mapper/dmcrypt$count ]; do count=$(( $count + 1 )); done
			echo "$savepassword" | cryptsetup luksFormat $tmpmount/$savefile
			echo "$savepassword" | cryptsetup open $tmpmount/$savefile dmcrypt$count
			DMCRYPT_DEVNAME=/dev/mapper/dmcrypt$count
			echo DMCRYPT_DEVNAME=$DMCRYPT_DEVNAME >> $BOOTSTATE_PATH
			mke2fs -F -m 0 -t $savefs $DMCRYPT_DEVNAME
			mount $DMCRYPT_DEVNAME $savefile_mount
			;;
			
		cryptoloop)
			### cryptoloop-based encryption - still works, but deprecated
			modprobe cryptoloop
			modprobe $ENCTYPE
			devloop=$(losetup-FULL -f)
			echo "$savepassword" | losetup-FULL -p 0 -e $ENCTYPE $devloop $tmpmount/$savefile
			mke2fs -F -m 0 -t $savefs $devloop
			mount $devloop $savefile_mount
			;;
	esac
	echo SAVEFILE_MOUNT=$savefile_mount >> $BOOTSTATE_PATH
	
	# move download folder if requested
	if [ "$movedownload" ]; then
		cp -a $DOWNLOAD_FOLDER $tmpmount/$savepath
		rm -rf $DOWNLOAD_FOLDER
		ln -s $savedownload $DOWNLOAD_FOLDER
		chown -R spot:spot $tmpmount/$savepath/${DOWNLOAD_FOLDER##*/}
		chown spot:spot $DOWNLOAD_FOLDER
	fi
	
	# change name and root password
	echo $hostname > /etc/hostname
	echo root:$rootpassword | chpasswd -m
	
	# done
	sync
	kill $xpid

	# keep savefile mounted, actual saving will be done by fatdog-merge-layers during shutdown ...
	msg="Done!\nSavefile $savefile has been created in $savedevice with encryption: $encrypted."
	[ "$movedownload" ] && msg="$msg\nDownloads folder moved to $savedownload."
	Xdialog --title "$APPTITLE" --infobox "$msg" 0 0 10000
	go_next
}

### multisession save is easy. All the hardwork is done in rc.shutdown
multisession_confirm() {
	local msg 

	msg=$(cat <<EOF
You have chosen to create a multisession save in $savedevice.

If you are using optical disc for multisession, please note:
- Only DVD is supported, and only DVD+RW has been tested.
- Please make sure that the DVD+RW already contains a copy of Fatdog
- Please make sure that the disc is inserted now.

Your other settings are:
- New hostname: $hostname
- New root password: $rootpassword

If all the above is well, click "Next" now. 
Otherwise click "Previous" to change your selection.
\n
EOF
)
	Xdialog --left --title "$APPTITLE" --backtitle "Confirm Selected Settings" --wizard --yesno "$msg" 0 0
	case $? in
		3) go_step 4 ;;
		1|255) prev_step=multisession-confirm; go_step warning ;;
		0) savefile_mount=$(mktemp -dp /tmp pupsave.XXXXXX)
		   multi_mount=$(mktemp -dp /tmp pupmulti.XXXXXX)
		   mount -t tmpfs tmpfs $savefile_mount
		   mount -t tmpfs tmpfs $multi_mount
		   
		   echo SAVEFILE_MOUNT=$savefile_mount >> $BOOTSTATE_PATH
		   echo MULTI_MOUNT=$multi_mount >> $BOOTSTATE_PATH
		   echo MULTI_DEVICE=${savedevice##*/} >> $BOOTSTATE_PATH
		   
		   # change name and root password
		   echo $hostname > /etc/hostname
		   echo root:$rootpassword | chpasswd -m
		   
		   go_step exit
		   ;;
	esac
}

choose_dir() {
	local choice msg
	msg="Enter the path for save directory on $savedevice. If it does not exist, it will be created. \
If you want to save to an entire partition, enter / (slash) as the save directory.\n"
	
	choice=$(Xdialog --fill --title "$APPTITLE" --backtitle "Save session to Directory" --wizard --stdout --inputbox "$msg" 0 0 "$savedir")
	case $? in
		0) savedir="$choice"; go_next ;;	# Xdialog ok
		3) go_step 5 ;;						# Xdialog previous
		1|255) go_step warning ;;			# Xdialog Esc/window kill
	esac
}

confirm_dir() {
	local msg 

	msg=$(cat <<EOF
You have chosen to save your session into a directory, as follows:

- Device location : $savedevice
- Directory : $savedir
- New hostname: $hostname
- New root password: $rootpassword

Make sure you get everything correct.
If you click "Next", the save action will proceed.
If some of the above are wrong, click "Previous" now and correct them.
EOF
)
	Xdialog --left --title "$APPTITLE" --backtitle "Confirm Selected Settings" --wizard --yesno "$msg" 0 0
	next_wizard_step
}

create_savedir() {
	# check if it's already mounted. If it does, use existing mount point
	dmdev=$(ls -l /dev/mapper 2> /dev/null | awk -v dmdev=${savedevice##*-} '$1 != "total" && $6 == dmdev {print "/dev/mapper/" $10; exit; }')	
	tmpmount=$(awk -v dev=$savedevice -v dmdev=$dmdev '$1 == dev || $1 == dmdev { print $2; exit; }' /proc/mounts)
	if [ -z "$tmpmount" ]; then	
		tmpmount=$(mktemp -dp /tmp devsave.XXXXXX)
		if ! case $savedevicetype in
			ntfs) ntfs-3g $savedevice $tmpmount	;;
			*) mount $savedevice $tmpmount ;;
		esac; then
			# failed to mount
			kill $xpid
			msg="Problem: Unable to access $savedevice, please choose another device/partition."		
			Xdialog --title "$APPTITLE" --msgbox "$msg" 0 0
			go_step 2
			
			rmdir $tmpmount	
			return
		fi
	fi

	# create the directory
	mkdir -p $tmpmount/$savedir
	echo SAVEFILE_MOUNT=$tmpmount/$savedir >> $BOOTSTATE_PATH
	
	# keep the directory mounted, actual saving will be done by fatdog-merge-layers during shutdown.
	msg="Done!\nDirectory $savedir has been created in $savedevice."
	Xdialog --title "$APPTITLE" --infobox "$msg" 0 0 10000
	
	# change name and root password
	echo $hostname > /etc/hostname
	echo root:$rootpassword | chpasswd -m

	go_step exit
}

################## main ###################
while true; do 
	case $step in 
		1) introduction ;;
		2) choose_hostname ;;
		3) change_root_password ;;
		4) choose_device ;;
		5) choose_savetype ;;	# branch to 50 if savetype=dir
		6) choose_size_and_name ;;
		7) choose_fs_and_encryption ;;
		8) choose_password ;;
		9) confirmation ;;
		10) create_savefile ;;
		11|exit) break ;;
		
		50) choose_dir ;;
		51) confirm_dir ;;
		52) create_savedir ;;
		
		warning) data_loss_warning ;;
		multisession-confirm) multisession_confirm ;;
	esac
done
