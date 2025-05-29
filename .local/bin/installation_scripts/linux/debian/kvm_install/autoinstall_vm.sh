#https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html
#!/bin/bash
mkdir -p cidata
cd cidata
cat > user-data << 'EOF'
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ubuntu-server
    password: "$6$exDY1mhS4KUYCE/2$zmn9ToZwTKLhCw.b4/b.ZRTIZM30JZ4QrOQ2aOXJ8yk96xpcCof0kxKwuX1kqLG/ygbJ1f8wxED22bTL4F46P0"
    username: ubuntu
EOF
touch meta-data

sudo apt install cloud-image-utils

cd ..
cloud-localds seed.iso cidata/user-data cidata/meta-data

truncate -s 10G image.img

kvm -no-reboot -m 2048 \
    -drive file=image.img,format=raw,cache=none,if=virtio \
    -drive file=seed.iso,format=raw,cache=none,if=virtio \
    -cdrom ~/src/ubuntu-24.04.2-live-server-amd64.iso

kvm -no-reboot -m 2048 \
    -drive file=image.img,format=raw,cache=none,if=virtio

