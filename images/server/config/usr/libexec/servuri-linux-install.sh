#!/bin/bash
# Installs servuri-linux to pre-created filesystems (for e.g. software RAID setup)
# 
set -euo pipefail

channel=$1
rootfs=$2
bootfs=$3

mkdir -p /var/servuri-install
mount -U $rootfs /var/servuri-install
mkdir -p /var/servuri-install/boot/efi
mount -U $bootfs /var/servuri-install/boot/efi
podman run --privileged --pid=host --rm \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    -v /var/servuri-install:/var/servuri-install \
    quay.io/bensku/servuri-linux/server:$channel \
    bootc install to-filesystem --composefs-backend --bootloader grub \
    /var/servuri-install
umount /var/servuri-install/boot/efi
umount /var/servuri-install
