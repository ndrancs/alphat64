#!/bin/sh
### rubah DEV sesuai dengan partisi yang akan di enc.
### dmcrypt10 is the device to create under /dev/mapper

#echo "passwd" | cryptsetup luksFormat /dev/sda6
#echo "passwd" | cryptsetup open /dev/sda6 dmcrypt10

### DMCRYPT_DEVNAME=/dev/mapper/dmcrypt$count

cryptsetup luksFormat /dev/sda6
cryptsetup open /dev/sda6 dmcrypt10
mke2fs -F -m 0 -t ext3 /dev/mapper/dmcrypt10
