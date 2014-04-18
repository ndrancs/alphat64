qemu-system-x86_64 -m 446 -no-reboot -initrd initrd -kernel vmlinuz -append "earlyshell lateshell" -enable-kvm -net nic,model=e1000 -net user -cdrom sfsBASE.iso -hdb hdb.img -boot c
/bin/find . | /usr/bin/cpio -o -H newc | /usr/bin/xz --check=crc32 --lzma2=dict=512KiB > ../initrd
find . -print | cpio -o -H newc | xz -f --extreme --check=crc32 > ../initrd
depmod 3.14.0-ALPHAOS -b squashfs-root
mksquashfs alpha_squashfs alphat64_100.sfs -comp xz
sha1sum alphat64_14.5.sfs > alphat64_14.5.sfs.sha1
xorriso -as mkisofs -RrJ -V "alphaT" -o sfsBASE.iso alphat64_100.sfs
privoxy --no-daemon /etc/privoxy/config
proxychains4 firefox
