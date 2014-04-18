#!/bin/sh

grep -q on-line /proc/acpi/ac_adapter/*/state && exit # exit if ac adapter is plugged already
grep -q 1 /sys/class/power_supply/*/online && exit # alternative check for ac adapter
[ -f /tmp/batt-low ] && exit	
touch /tmp/batt-low
Xdialog --title "Battery Low" --infobox "Your Battery is low." 0 0 10000