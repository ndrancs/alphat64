#!/bin/bash
# $1 = wlan0 , $2 = ppp0
#Initial wifi interface configuration
ifconfig $1 up 192.168.1.254 netmask 255.255.255.0

###########Start DHCP, comment out / add relevant section##########

#dhcpd wlan0 &

###########
#Enable NAT
#iptables --flush
#iptables --table nat --flush
#iptables --delete-chain
#iptables --table nat --delete-chain
#iptables --table nat --append POSTROUTING --out-interface $2 -j MASQUERADE
#iptables --append FORWARD --in-interface $1 -j ACCEPT
#echo "1" > /proc/sys/net/ipv4/ip_forward

iptables -t nat -A POSTROUTING -o $2 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward

#sysctl -w net.ipv4.ip_forward=1

#start hostapd
hostapd /etc/hostapd.conf 1>/dev/null
ifconfig $1 up 192.168.1.254 netmask 255.255.255.0
