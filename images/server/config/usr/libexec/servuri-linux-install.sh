#!/bin/bash
# Installs servuri-linux to pre-created filesystems (for e.g. software RAID setup)
# 
set -euo pipefail

channel=$1
rootfs=$2
bootfs=$3

sudo podman run --privileged --pid=host --rm quay.io/bensku/servuri-linux/server:$channel \
    bootc install to-filesystem --composefs-backend --bootloader grub \
    --root-mount-spec=$rootfs --boot-mount-spec=$bootfs --replace=wipe