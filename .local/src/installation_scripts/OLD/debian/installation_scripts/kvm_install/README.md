# kvm_install

## create seed.iso
```
cloud-localds seed.iso cidata/user-data cidata/meta-data 
```

## create image.img
```
truncate -s 10G image.img
```

## install iso
```
kvm -no-reboot -m 2048 \
    -drive file=image.img,format=raw,cache=none,if=virtio \
    -drive file=seed.iso,format=raw,cache=none,if=virtio \
    -cdrom ~/src/ubuntu-24.04.2-live-server-amd64.iso
```

## can reboot without iso
```
kvm -no-reboot -m 2048 \
    -drive file=image.img,format=raw,cache=none,if=virtio
```
