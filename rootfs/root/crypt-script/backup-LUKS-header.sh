#!/bin/sh
### to backup header

cryptsetup luksHeaderBackup --header-backup-file /root/bakHeadLuks.sda6 /dev/sda6

### To restore, use the inverse command, i.e.

cryptsetup luksHeaderRestore --header-backup-file /root/bakHeadLuks.sda6 /dev/sda6
