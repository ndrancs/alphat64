#!/bin/dash
# Network Setup
# This will be CLI (so that it can be used on non-graphical systems)
#
# Copyright (C) James Budiono 2014
# License: GNU GPL Version 3 or later.
#
# Note: handles WEP/WPA/WPA2 and open system.
# WEP support is only for "OPEN" authentication (for SHARED, edit config file)
# WEP key can be in hexadecimal or "ASCII".
# If you need anything more serious then you can hand-craft your wpa config.
#

### configuration
APPTITLE="Network Configuration"
XTERM="urxvt"
#CFG_DIR=/tmp/network-setup
CFG_DIR=/etc/network-setup
CFG_IP_DIR=$CFG_DIR/ip
CFG_ACCESS_DIR=$CFG_DIR/access

BEGIN_MARKER="### Generated by network-setup.sh, do not edit."
END_MARKER="######"

### configurable setup
DHCPCD_TIMEOUT=120     # 120 seconds
WPA_CONNECT_TIMEOUT=15 # 15 seconds - wait for wpa_supplicant to get connection
IFACE_TIMEOUT=15       # 15 seconds - wait for interface to show up
[ -e /etc/net-setup.conf ] && . /etc/net-setup.conf # override

### run-time variables
ANS_FILE=/tmp/ans.$$          # output from dialog
SCAN_RESULT=/tmp/wlan_scan.$$ # scan result
TMP_WPA=/tmp/wpa.$$           # temporary/partially constructed config file
[ $BOOTSTATE_PATH ] && [ -e $BOOTSTATE_PATH ] && . $BOOTSTATE_PATH


################################
########## helpers #############
################################

trap 'cleanup; exit;' HUP INT TERM

cleanup() {
	rm -f $ANS_FILE $SCAN_RESULT $TMP_WPA
}

### make our life with dialog a bit easier
# input: $@, output: $ans, $?
dlg() {
	local ret
	dialog --backtitle "$APPTITLE" "$@" 2> $ANS_FILE; ret=$?
	ans=$(cat $ANS_FILE) # because ans can be multiple lines
	return $ret
}

### $*-msg to display
msgbox() {
	dlg --msgbox "$*" 0 0
}

### $*-msg to display
infobox() {
	dlg --infobox "$*" 0 0
}

### make sure we run as root - input $@
run_as_root() {
	if [ $(id -u) -ne 0 ]; then
		if [ $DISPLAY ]; then
			exec gtksu "$APPTITLE" "$0" "$@"
		else
			eval exec su -c \""$0 $@"\"
		fi
	fi
}

### make sure we run in terminal - input: $@
run_in_terminal() {
	# check we're running in terminal, if not, re-exec
	if ! test -t 0; then
		# not on terminal, re-exec on terminal
		if [ $DISPLAY ]; then
			exec $XTERM -e "$0" "$@"
		else
			exit
		fi
	fi
}

###
is_configured_by_initrd() {
	# don't touch if network already set by initrd
	if [ "$CONFIGURED_NET" ]; then
		[ $RC_NETWORK_PID ] && rm -f $RC_NETWORK_PID
		return 0
	fi
	return 1
}

### $1-interface
is_managed_by_wpagui() {
	# don't touch interfaces managed by WpaGui
	is_wireless $1 && [ -f /etc/wpagui ] && return 0
	return 1
}

### $1-interface
is_wireless() {
	test -e /sys/class/net/$1/wireless
}

### output: $interfaces (lo not included)
get_interfaces() {
	interfaces=$(ls /sys/class/net | grep -v lo 2>/dev/null)
}

### output: configs
get_ip_configs() {
	configs=$(ls $CFG_IP_DIR 2>/dev/null)
}

### input: $1-interface, output: configs
get_access_configs() {
	configs=$(ls $CFG_ACCESS_DIR 2>/dev/null | grep ^$1)
}

### check ipv4 validity, $1-ip
# this is a bit stupid but it's better than nothing, I don't want to call
# external binaries just to do this
is_valid_ipv4() {
	local IFS p
	IFS=.; set -- $1
	[ $# -ne 4 ] && return 1 # must have 4 components
	for p; do
		if [ $p -lt 0 ] || [ $p -gt 255 ]; then
			return 1 # bad each component must be between 0..255
		fi
	done
	return 0
}

### $1-prog to kill $2-interface
kill_prog() {
	local p
	for p in $(pidof $1); do
		grep -q $2 /proc/$p/cmdline && kill $p
	done
}

### $1-interface, output in $SCAN_RESULT (file)
wlan_scan() {
	local interface=$1 p MAC QUALITY ESSID SEC ENC
	
	# not wireless - can't scan
	! is_wireless $1 && return 1
	
	# reset interface - not sure if really needed? But anyway ...
	kill_prog wpa_supplicant $1
	kill_prog dhcpcd $1
	{ ifconfig $1 down; sleep 2; ifconfig $1 up; } > /dev/null
	
	# scan and parse
	rm -f $SCAN_RESULT
	MAC="" QUALITY="" ESSID="" SEC="" ENC=""
	while read p; do
		case "$p" in
			*Cell*) 
				[ "$MAC" ] && dump_scan_info # dump previous scan result
				MAC="" QUALITY="" ESSID="" SEC=""
				MAC=${p#*Address: } ;;
			*Quality*)
				QUALITY=${p%% *}; QUALITY=${QUALITY#Quality=} ;;
			*ESSID*)
				ESSID=${p#*ESSID:}; ESSID=${ESSID#*\"}; ESSID=${ESSID%\"*} ;;
			*"key:on"*)
				ENC="on" ;; # remember that encryption is on
			# detect supported security protocol
			*"WPA Version"*)
				SEC="wpa $SEC" ;;
			*"WPA2 Version"*)
				SEC="wpa2 $SEC" ;;
		esac
	done << EOF
$(iwlist $1 scanning)
EOF
	[ "$MAC" ] && dump_scan_info # last un-dumped info
	
	# sort by quality (highest first)
	if [ -e $SCAN_RESULT ]; then
		sort -r < $SCAN_RESULT > ${SCAN_RESULT}.tmp
		mv ${SCAN_RESULT}.tmp $SCAN_RESULT
		return 0
	else
		return 1 # fail
	fi
}
dump_scan_info() {
	[ -z "$ESSID" ] && ESSID="Hidden Network"
	[ -z "$SEC" ] && [ "$ENC" ] && SEC="wep" # no security with encryption on is WEP
	[ -z "$SEC" ] && SEC="open"
	# quality first so we can sort it
	echo "$QUALITY|$ESSID|$MAC|$SEC" >> $SCAN_RESULT 
}

### $1-scan info (as dumped by dump_scan_info), output: MAC QUALITY ESSID SEC
load_scan_info() {
	local IFS
	IFS="|"
	set -- $1
	QUALITY="$1" ESSID="$2" MAC="$3" SEC="$4"
	#echo "$QUALITY|$ESSID|$MAC|$SEC"
}

### input: $1-proforma filename; output: $ans (sanitised name)
sanitise_filename() {
	ans=$(echo "$1" | tr -d '/\\ \t\n\r?*#^&$()!~|:')
}


####################################################
########## configuration commands - ip #############
####################################################



### $1-interface
write_config_ip_dhcp() {
	mkdir -p $CFG_IP_DIR
	echo "set_ip() { dhcpcd -t $DHCPCD_TIMEOUT -L -h \$(hostname) $1; }" > $CFG_IP_DIR/$1
}

### $1-interface, $@ ip/netmask/gw/dns1/dns2
write_config_ip_static() {
	local interface vars var
	interface=$1
	vars="IP|NETMASK|DEFAULT_GW|DNS1|DNS2"
	
	mkdir -p $CFG_IP_DIR
	shift
	echo "$BEGIN_MARKER" > $CFG_IP_DIR/$interface
	while [ "$1" ]; do
		var=${vars%%|*}
		vars=${vars#$var|}
		echo "$var='$1'"
		shift
	done >> $CFG_IP_DIR/$interface
	cat >> $CFG_IP_DIR/$interface << EOF
set_ip() {
	ifconfig $interface \$IP netmask \$NETMASK
	route add default gw \$DEFAULT_GW dev $interface
	echo nameserver \$DNS1 >  /etc/resolv.conf
	echo nameserver \$DNS2 >> /etc/resolv.conf
}
EOF
}

### $1-interface, output IP NETMASK DEFAULT_GW DNS1 DNS2
load_config_ip_static() {
	IP="" NETMASK="" DEFAULT_GW="" DNS1="" DNS2=""
	[ -e $CFG_IP_DIR/$1 ] && . $CFG_IP_DIR/$1
}



################################################################
########## configuration commands - access profile #############
################################################################

### input: $1-interface, output: $ans=filename
create_manual_access_profile() {
	local p=1 pname="${1}-manual"
	
	while [ -e $CFG_ACCESS_DIR/${pname}${p} ]; do
		p=$((p+1))
	done
	pname=${pname}${p}

	mkdir -p $CFG_ACCESS_DIR
	cat > $CFG_ACCESS_DIR/$pname << EOF
# Edit your own wpa_supplicant configuration here
# Lines preceeded by # like this one is ignored

ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=users
update_config=1

# Example - modify to suit your own
# network={
#	ssid="your wifi ssid"
#   psk="your wifi password"
# }

EOF
	ans=$pname
}

### input: $1-interface $2-MAC; output: $ans=profile filename
create_new_access_profile() {
	local pname p MAC QUALITY ESSID SEC
	
	load_scan_info "$(grep $2 $SCAN_RESULT)"
	sanitise_filename "$ESSID"; pname=$1-$ans
	case "$ESSID" in # if ESSID is hidden, make sure we don't existing
		Hidden*)
			p=1
			while [ -e $CFG_ACCESS_DIR/${pname}${p} ]; do
				p=$((p+1))
			done
			pname=${pname}${p} ;;
	esac
	
	# create
	mkdir -p $CFG_ACCESS_DIR
	cat > $CFG_ACCESS_DIR/$pname << EOF
$BEGIN_MARKER
#MAC='$MAC'
#SEC='$SEC'
#ESSID='$ESSID'
$END_MARKER
EOF
	ans=$pname
}

### input: $1-file, output: ESSID MAC SEC CHOSEN_SEC CHOSEN_MAC SEC_PASS DISABLED USE_WEXT
load_config_access_profile() {
	ESSID="" MAC="" SEC="" CHOSEN_SEC="" CHOSEN_MAC="" SEC_PASS="" DISABLED="" USE_WEXT=""
	eval $(sed "/$BEGIN_MARKER/,/$END_MARKER/!d; /$BEGIN_MARKER/d; /$END_MARKER/d; s/^#//" $1)
	[ -z "$CHOSEN_SEC" ] && CHOSEN_SEC=${SEC%% *}
}

### input: $1-file, $2-ans file 
write_config_access_profile() {
	local items item p 
	local ESSID MAC SEC CHOSEN_SEC CHOSEN_MAC SEC_PASS DISABLED USE_WEXT WEP_IDX
	local PSK PROTO BSSID KEY_MGMT AUTH_ALG WEP_KEY WEP_KEY_IDX
	
	# generate tmp, keep only SEC and MAC (those came from wlan_scan)
	sed "/$BEGIN_MARKER/,/$END_MARKER/!d; /$END_MARKER/d; \
	     /CHOSEN_SEC/d; /CHOSEN_MAC/d; /ESSID/d; /DISABLED/d; /USE_WEXT/d; /WEP_IDX/d" \
	     $CFG_ACCESS_DIR/$1 > $TMP_WPA
	
	# get user-defined variables and append it to the file
	items="ESSID|CHOSEN_SEC|SEC_PASS|DISABLED|CHOSEN_MAC|USE_WEXT|WEP_IDX"
	while read -r p; do
		item=${items%%|*}
		items=${items#$item|}
		[ "$p" ] && echo "#$item='$p'" >> $TMP_WPA
	done < "$2"
	echo "$END_MARKER" >> $TMP_WPA
	
	# load all data
	load_config_access_profile $TMP_WPA
	
	# pre-calc parameters for wpa, wpa2, open and wep
	[ "$CHOSEN_MAC" ] && BSSID="bssid=$CHOSEN_MAC"
	case $CHOSEN_SEC in
		wpa|wpa2) 
			KEY_MGMT="key_mgmt=WPA-PSK"		
			AUTH_ALG="auth_alg=OPEN"
			PROTO="proto=WPA RSN"
			PSK=$(sed '/psk/!d; s/[ \t]//' $CFG_ACCESS_DIR/$1)
			[ $SEC_PASS ] && PSK=$(wpa_passphrase "$ESSID" "$SEC_PASS" | sed '/psk/!d; /#psk/d; s/[ \t]//')
			WEP_KEY="" WEP_KEY_IDX=""
			;;
		open)
			KEY_MGMT="key_mgmt=NONE"
			AUTH_ALG="auth_alg=OPEN"
			PROTO="" PSK=""
			WEP_KEY="" WEP_KEY_IDX=""
			;;
		wep)
			KEY_MGMT="key_mgmt=NONE"
			AUTH_ALG="auth_alg=OPEN"      # we only support OPEN authentication
			[ -z $WEP_IDX ] && WEP_IDX=1
			[ -z "$SEC_PASS" ] && SEC_PASS=$(sed '/wep_key/!d; s/.*=//' $CFG_ACCESS_DIR/$1)			
			WEP_KEY_IDX="wep_tx_keyidx=$((WEP_IDX-1))"
			WEP_KEY="wep_key$((WEP_IDX-1))=$SEC_PASS"  
			PROTO="" PSK=""
			;;
	esac
	
	# all know security protocols uses wpa_supplicant, so generate its config file
	cat >> $TMP_WPA << EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=users
update_config=1

network={
	ssid="$ESSID"
	$KEY_MGMT
	$AUTH_ALG
	$PROTO
	$PSK
	$WEP_KEY
	$WEP_KEY_IDX
	$BSSID
}
EOF
	
	grep -v SEC_PASS $TMP_WPA > $CFG_ACCESS_DIR/$1
	rm -f $TMP_WPA

}



############################################################
########## configuration commands - activation #############
############################################################

### $1-interface, output: PROFILE
activate_find_profile() {
	local ENABLED_PROFILES="" p
	
	# find the correct profile file to use based on available networks
	#exec 2> /dev/pts/0; set -x
	ENABLED_PROFILES="$(grep -L DISABLED $CFG_ACCESS_DIR/${interface}* 2>/dev/null)"
	if wlan_scan $interface; then
		while read -r p; do
			PROFILE="$(grep -m 1 -Fl "$p" $ENABLED_PROFILES)" # take the the first one
			[ "$PROFILE" ] && break
		done << EOF
$(awk -F"|" '{print $2}' $SCAN_RESULT)
EOF
	fi
	
	# if can't find anything, choose the first enabled manual profile
	[ -z "$PROFILE" ] && PROFILE="$(echo "$ENABLED_PROFILES" | grep -m 1 manual)"
	[ -z "$PROFILE" ] && return 1 # fail if we can't find anything
	return 0
}

### $1-interface $2-profile (auto is special)
activate_access_profile() {
	local interface=$1 PROFILE=$2
	local CONNECT_MODE=-Dnl80211 TIMEOUT=$WPA_CONNECT_TIMEOUT
	
	case "$PROFILE" in
		""|auto) if ! activate_find_profile $interface; then
					is_wireless $interface && return 1 # fail for wireless
					return 0 # but ok (and don't do anything else) for wired
				 fi ;;
		*) PROFILE="$CFG_ACCESS_DIR/$PROFILE" ;;
	esac
	
	# all known security protocols run wpa_supplicant
	grep -q USE_WEXT "$PROFILE" && CONNECT_MODE=-Dwext
	wpa_supplicant -B -i $interface $CONNECT_MODE -c "$PROFILE" > /dev/null
	while [ $TIMEOUT -ne 0 ]; do
		wpa_cli -i $interface status 2>/dev/null | grep -q COMPLETED && return 0
		sleep 1
		TIMEOUT=$((TIMEOUT-1))
	done
	return 1
}

### $1-interface
activate_ip() {
	[ -e $CFG_IP_DIR/$1 ] && . $CFG_IP_DIR/$1
	type set_ip >/dev/null && set_ip > /dev/null 2>&1
}

### $1-interface
activate_interface() {
	local TIMEOUT=$IFACE_TIMEOUT
	[ -e $CFG_IP_DIR/$1 ] || return 1 # ignore non-configured interface
	
	# wait until interface appears
	while [ $TIMEOUT -ne 0 ]; do
		test -e /sys/class/net/$1 && break
		sleep 1
		TIMEOUT=$((TIMEOUT-1))
	done
	
	# no interface - leave
	! [ -e /sys/class/net/$1 ] && return 1
	
	ifconfig $1 up > /dev/null &&
	activate_access_profile $1 &&
	activate_ip $1
}

### $1-interface
deactivate_interface() {
	[ -e $CFG_IP_DIR/$1 ] || return 1 # ignore non-configured interface	
	kill_prog dhcpcd $1
	kill_prog wpa_supplicant $1
	ifconfig $1 0.0.0.0 # release IP address 
	ifconfig $1 down
	return 0
}



########################################
########## user interfaces #############
########################################



### main entry point for UI
ui_main() {
	local WPAGUI
	while true; do
		WPAGUI="enable-wpagui 'Enable WpaGui'"
		[ -e /etc/wpagui ] && WPAGUI="disable-wpagui 'Disable WpaGui'"
		eval dlg --no-tags --menu "'Main Menu'" 0 0 0 \
			config-ip     "'Configure IP address'" \
			config-access "'Configure access profile'" \
			activate      "'Activate settings now'" \
			$WPAGUI \
			exit "Exit" || break
		case $ans in
			config-ip)     ui_choose_interfaces ui_ip ;;
			config-access) ui_choose_interfaces ui_access ;;
			activate)      ui_choose_interfaces ui_activate ;;
			enable-wpagui)  touch /etc/wpagui ;;
			disable-wpagui) rm -f /etc/wpagui    ;;
			exit) break ;;
		esac
	done
}

### input: $1-next function to call, output: $interface
ui_choose_interfaces() {
	local next_func pp=""
	next_func=$1
	
	get_interfaces
	for p in $interfaces; do
		pp="$pp $p $p"
	done
	
	while true; do
		dlg --no-tags --menu "Choose interfaces to configure" 0 0 0 $pp \
			sep "---" back "Back" || break
		case $ans in
			sep) ;;
			back) break ;;
			*) $next_func $ans && break ;;
		esac
	done
}



########## IP configuration UI ############



### $1-interface
ui_ip() {
	local interface=$1 del
	while true; do
		[ -e $CFG_IP_DIR/$interface ] && del="remove 'Remove existing configuration'"
		eval dlg --no-tags --menu "'Configure IP address for $interface'" 0 0 0 \
			dhcp      "'Auto-configure using DHCP'" \
			static-ip "'Use static IP'" $del \
			sep "'---'" back "'Back'" || return 1
		case $ans in
			sep) ;;
			back) return 1 ;;
			dhcp) write_config_ip_dhcp $interface 
				  msgbox "$interface configured to use dhcp."
				  break ;;
				  
			static-ip) 
			      ui_ip_static $interface && 
			      msgbox "$interface configured with static IP." &&
			      break ;;
			      
			remove)
			      rm -f $CFG_IP_DIR/$interface
			      break ;;
		esac
	done
	return 0
}

### $1-interface
ui_ip_static() {
	local interface label labels p
	local IP NETMASK DEFAULT_GW DNS1 DNS2
	
	# load existing values
	interface=$1 
	load_config_ip_static $interface
	[ -z $IP ] &&         IP="0.0.0.0" 
	[ -z $NETMASK ] &&    NETMASK="255.255.255.0" 
	[ -z $DEFAULT_GW ] && DEFAULT_GW="0.0.0.0"
	[ -z $DNS1 ] &&       DNS1="8.8.8.8" 
	[ -z $DNS2 ] &&       DNS2="8.8.4.4"
	
	# edit
	while true; do
		dlg --form "Configure static IP for $interface" 0 0 0 \
		"IP address"      1 1 "$IP"         1 20 16 0 \
		"Netmask"         2 1 "$NETMASK"    2 20 16 0 \
		"Default Gateway" 3 1 "$DEFAULT_GW" 3 20 16 0 \
		"DNS server 1"    4 1 "$DNS1"       4 20 16 0 \
		"DNS server 2"    5 1 "$DNS2"       5 20 16 0 || return 1

		# validation
		labels="IP address|Netmask|Default Gateway|DNS server 1|DNS server 2|"
		for p in $ans; do
			label=${labels%%|*}
			labels=${labels#$label|}
			if ! is_valid_ipv4 $p; then
				msgbox "$p is invalid ${label}."
				continue 2
			fi
		done
		
		# store the config
		write_config_ip_static $interface $ans
		break
	done
	return 0
}



########## Access profile configuration UI ############



### $1-interface
ui_access() {
	local configs interface=$1 pp="" p SCAN_MENU="" DEL_MENU

	is_wireless $1 && SCAN_MENU="new-scan 'New profile from existing Wi-Fi networks'"	
	while true; do
		get_access_configs $1
		pp="" DEL_MENU=""
		[ "$configs" ] && DEL_MENU="del-profile 'Delete existing profile(s)'"
		for p in $configs; do
			pp="$pp '${p#${interface}-}' '${p#${interface}-}'"
		done
		

		eval dlg --no-tags --menu "'Configure access profile for $interface'" 0 0 0 \
			$SCAN_MENU \
			new-manual  "'New profile (manual configuration)'" \
			$DEL_MENU \
			$pp \
			sep "'---'" back "'Back'" || return 1
		case $ans in
			sep) ;;
			back) return 1 ;;
			new-scan)    ui_access_new_from_scan $interface && break ;;
			new-manual)  ui_access_new_manual $interface && break  ;;
			del-profile) ui_access_delete_profile $interface ;;
			*) ui_access_edit $interface-$ans && break ;;
		esac
	done
	return 0
}

### $1-interface
ui_access_delete_profile() {
	local configs interface=$1 pp="" p

	while true; do
		get_access_configs $1
		[ -z "$configs" ] && break 
		
		pp=""
		for p in $configs; do
			pp="$pp ${p#${interface}-} ${p#${interface}-}"
		done

		dlg --no-tags --menu "DELETE profile for $interface" 0 0 0 \
			$pp \
			sep "---" back "Back" || return 1
		case $ans in
			sep) ;;
			back) return 1 ;;
			*) rm -f $CFG_ACCESS_DIR/$interface-$ans ;;
		esac
	done
	return 0	
}

### $1-interface
ui_access_new_from_scan() {
	local pp="" p MAC ESSID QUALITY SEC interface=$1
	
	infobox "Scanning for wireless network, please wait ..."
	if wlan_scan $1; then
		while read -r p; do
			load_scan_info "$p"
			pp="$pp $MAC \"$ESSID ($MAC) $QUALITY, $SEC\""
		done << EOF
$(cat $SCAN_RESULT)
EOF
		while true; do	
			eval dlg --no-tags --menu \""Choose wireless network"\" 0 0 0 $pp \
			     sep \""---"\" back Back || return 1
			
			case $ans in
				sep) ;;
				back) return 1 ;;
				*) create_new_access_profile $interface $ans && # $ans=filename
                   ui_access_edit $ans && break
			esac
		done
		
	else
		return 1
	fi
	return 0
}

### $1-interface
ui_access_new_manual() {
	create_manual_access_profile $1 &&
	ui_access_edit_manual "$ans"
}

### $1-file
ui_access_edit() {
	local fn="$1"
	
	# manual edit?
	if ! grep -q "$BEGIN_MARKER" $CFG_ACCESS_DIR/$fn; then
		ui_access_edit_manual "$fn"
		return
	fi
	ui_access_edit_form "$fn"
}

### $1-file
ui_access_edit_manual() {
	local fn="$1"
	if dlg --title "Editing $fn" --editbox "$CFG_ACCESS_DIR/$fn" 0 0; then
		mv $ANS_FILE "$CFG_ACCESS_DIR/$fn"
		msgbox "$fn edited successfully."
	else
		msgbox "$fn not modified."
		return 1
	fi
	return 0
}

### $1-file
ui_access_edit_form() {
	local MAC ESSID SEC CHOSEN_SEC CHOSEN_MAC SEC_PASS DISABLED USE_WEXT WEP_IDX
	local fn="$1" p labels label WEP_KEY_MENU=""

	load_config_access_profile "$CFG_ACCESS_DIR/$fn"
	case $CHOSEN_SEC in *wep*) 
		[ -z $WEP_IDX ] && WEP_IDX=1
		WEP_KEY_MENU="'WEP key index (1-4)' 9 1 '$WEP_IDX' 9 30 28 1" 
	esac
	while true; do
		eval dlg --form "'Configure access profile for $interface'" 0 0 0 \
		"'SSID'"                       1 1 "'$ESSID'"      1 30  28 64 \
		"'Security ($SEC)'"            2 1 "'$CHOSEN_SEC'" 2 30  28  4 \
		"'Password (blank=no change)'" 3 1 "'$SEC_PASS'"   3 30  28 64 \
		"'Disable  (yes=disable)'"     4 1 "'$DISABLED'"   4 30  28  3 \
		"'-- Advanced settings --'"    6 1 "''"            6 30   0  0 \
		"'AP MAC ($MAC)'"              7 1 "'$CHOSEN_MAC'" 7 30  28 17 \
		"'Use Wext (blank=nl80211)'"   8 1 "'$USE_WEXT'"   8 30  28  3 \
		$WEP_KEY_MENU || return 1
		
		# validation
		labels="ESSID|Security|"
		while read -r p; do
			label=${labels%%|*}
			labels=${labels#$label|}
			[ -z "$label" ] && break
			if [ -z "$p" ]; then
				msgbox "${label} cannot be blank."
				continue 2
			fi
		done < $ANS_FILE
		
		write_config_access_profile "$fn" $ANS_FILE
		break
	done
	return 0
}


########## Manual activation UI ############


### $1-interface
ui_activate() {
	local configs interface=$1 pp="" p profile="auto"

	get_access_configs $1
	[ "$configs" ] && for p in $configs; do
		pp="$pp '${p#${interface}-}' '${p#${interface}-}'"
	done
	
	[ "$configs" ] && while true; do
		eval dlg --no-tags --menu "'Activate access profile for $interface'" 0 0 0 \
			auto  "'Automatic (use whatever is available)'" \
			$pp \
			sep "'---'" back "'Back'" || return 1
		case $ans in
			sep) ;;
			back) return 1 ;;
			*) profile=$interface-$ans; break ;;
		esac
	done

	infobox "Attempting to activate $interface (profile: ${profile#${interface}-}), please wait ..."
	deactivate_interface $interface
	activate_interface $interface $profile && 
	msgbox "$interface activated (profile: ${profile#${interface}-})" ||
	msgbox "$interface failed to be activated (profile: ${profile#${interface}-})"
}



#########################################
########## at-boot services #############
#########################################

###
start_loopback() {
	ifconfig lo up
	ifconfig lo 127.0.0.1
	route add -net 127.0.0.0 netmask 255.0.0.0 lo 2> /dev/null
}


### 
start_network() {
	local PIDS=""
	
	# don't touch if network already set by initrd
	is_configured_by_initrd && return
	
	# for all configured interfaces, activate it
	start_loopback
	get_ip_configs
	for p in $configs; do
		is_managed_by_wpagui $p && continue	
		echo Starting interface $p
		activate_interface $p auto &
		PIDS="$PIDS $!"
	done
	
	# wait for all instances to finish & and then delete the stuff
	wait $PIDS
	[ $RC_NETWORK_PID ] && rm -f $RC_NETWORK_PID
}

### 
stop_network() {
	# don't touch if network already set by initrd
	is_configured_by_initrd && return
	
	# for all configured interfaces that are not wpagui's, stop it
	get_ip_configs
	for p in $configs; do
		is_managed_by_wpagui $p && continue 
		echo Stopping interface $p
		deactivate_interface $p &
	done
}

############
### main ###
############
run_as_root "$@"
case $1 in
	-h|--help) echo "${0##*/} [start|stop]" ;;
	start)     start_network ;;
	stop)      stop_network ;;
	"") if [ ${0##*/} = rc.network ]; then
			start_network
		else
			run_in_terminal "$@"
			ui_main
			clear
		fi ;;
esac
cleanup
