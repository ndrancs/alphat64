#!/bin/sh
### rubah DEV sesuai dengan partisi yang akan di open.
### dmcrypt10 is the device to create under /dev/mapper

cryptsetup open /dev/sda7 dmcrypt10

