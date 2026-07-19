#!/bin/bash
# Replaces the running OS with servuri-linux
# This is meant to be invoked INSIDE the image:
# mkdir -p /run/bootc-empty-udev
# podman run --rm --privileged -v /dev:/dev -v /run/bootc-empty-udev:/run/udev:ro -v /var/lib/containers:/var/lib/containers -v /:/target --pid=host --security-opt label=type:unconfined_t quay.io/bensku/servuri-linux/server:dev /usr/libexec/servuri-become.sh
set -euo pipefail

bootc install to-existing-root \
    --composefs-backend --bootloader=grub --cleanup