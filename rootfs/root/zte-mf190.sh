#!/bin/bash
eject /dev/sr0
eject /dev/sr1
sleep 5s
#modprobe usbserial vendor=0x201e product=0x1022
echo "modem zte siap digunakan"
