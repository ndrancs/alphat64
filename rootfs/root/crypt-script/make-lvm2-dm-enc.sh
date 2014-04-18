#!/bin/sh

#format partisi dengan LUKS, dengan ukuran partisi ditentukan sebelumnya. misal: 40GB
cryptsetup luksFormat /dev/sda1

#open/aktifkan partisi hasil format tadi, akan muncul di /dev/mapper/<nama yang kita berikan>
cryptsetup open /dev/sda1 sda1_crypt

#buat PV pada partisi tadi, misal tadi: /dev/mapper/sda1_crypt
lvm pvcreate /dev/mapper/sda1_crypt

#buat VG pada PV tadi. misal namanya: VG1, note VG bisa terdiri dari beberapa PV, sda1, sdb1, dst.
lvm vgcreate VG1 /dev/mapper/sda1_crypt

#buat LV pada VG. misal pada VG1 yang tadi kita buat. LV ini kita kasih nama misal: LV1video dengan ukuran 10GB
lvm lvcreate -v -n LV1video -L 10GB VG1 /dev/mapper/sda1_crypt

#supaya LV1video bisa digunakan maka harus diformat terlebih dahulu. misal dengan FS type: xfs
mkfs.xfs /dev/VG1/LV1video

#tes mount
mkdir /mnt/LV1
mount /dev/VG1/LV1video /mnt/LV1

#buat LV lainnya.
lvm lvcreate -v -n LV2data -L 10GB VG1 /dev/mapper/sda1_crypt

#format LV2data misal pake FS type: reiserfs
mkfs.reiserfs /dev/VG1/LV2data 

#tes mount lagi.
mkdir /mnt/LV2
mount /dev/VG1/LV2data /mnt/LV2

#untuk melihat PV yang ada.
lvm pvs

#untuk VG
lvm vgs

#untuk LV
lvm lvs



