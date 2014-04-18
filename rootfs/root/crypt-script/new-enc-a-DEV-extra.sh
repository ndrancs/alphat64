#!/bin/sh
### rubah DEV sesuai dengan partisi yang akan di enc.
### dmcrypt10 is the device to create under /dev/mapper

#echo "passwd" | cryptsetup luksFormat /dev/sda6
#echo "passwd" | cryptsetup open /dev/sda6 dmcrypt10

### DMCRYPT_DEVNAME=/dev/mapper/dmcrypt$count
###Default compiled-in device cipher parameters:
###	loop-AES: aes, Key 256 bits
###	plain: aes-cbc-essiv:sha256, Key: 256 bits, Password hashing: ripemd160
###	LUKS1: aes-xts-plain64, Key: 256 bits, LUKS header hashing: sha1, RNG: /dev/urandom <-- default cipher mode.
# cryptsetup -c aes-cbc-essiv:sha256 -y -s 256 luksFormat /dev/sde1
# cryptsetup -y --cipher aes-xts-plain --key-size 512 luksFormat /dev/sdb5

cryptsetup luksFormat /dev/sda6
cryptsetup open /dev/sda6 dmcrypt10
mke2fs -F -m 0 -t ext3 /dev/mapper/dmcrypt10
