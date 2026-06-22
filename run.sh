#!/bin/bash
set -euo pipefail

IMAGE=$1
MODE="${2:-bios}"

qemu_args=(
	-accel kvm
	-m 2G
	-machine q35
	-drive format=raw,file=$IMAGE,if=virtio
	-netdev user,id=net0,hostfwd=tcp::2222-:22
	-device virtio-net-pci,netdev=net0
)

case "${MODE,,}" in
	bios)
		;;
	efi|uefi)
		ovmf_code=/usr/share/qemu/ovmf-x86_64-4m-code.bin
		ovmf_vars_template=/usr/share/qemu/ovmf-x86_64-4m-vars.bin
		ovmf_vars=ovmf-vars.bin

		if [ ! -f "$ovmf_code" ]; then
			echo "OVMF firmware not found at $ovmf_code (install the 'qemu-ovmf-x86_64' package)" >&2
			exit 1
		fi
		# Per-VM writable copy of the variable store.
		if [ ! -f "$ovmf_vars" ]; then
			cp "$ovmf_vars_template" "$ovmf_vars"
		fi

		qemu_args+=(
			-drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code"
			-drive "if=pflash,format=raw,unit=1,file=$ovmf_vars"
		)
		;;
	*)
		echo "Usage: $0 [bios|efi]" >&2
		exit 1
		;;
esac

qemu-system-x86_64 "${qemu_args[@]}"
