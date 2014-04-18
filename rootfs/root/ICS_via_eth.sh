#!/bin/bash
# $1 = eth0 , $2 = ppp0

ifconfig $1 down
ifconfig $1 up 192.168.137.1 netmask 255.255.255.0

iptables -t nat -A POSTROUTING -o $2 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward

ifconfig $1 up 192.168.137.1 netmask 255.255.255.0

dnsd -v -s -c /etc/resolv.conf
