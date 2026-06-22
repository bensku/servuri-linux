image_base := "quay.io/bensku/servuri-linux"

build IMAGE:
    sudo podman build --build-arg IMAGE_BASE="{{image_base}}" -t {{image_base}}/{{IMAGE}} -f images/{{IMAGE}}/Containerfile .

build-all: && (build "base") (build "server-base") (build "server")

push IMAGE CHANNEL:
    sudo podman tag {{image_base}}/{{IMAGE}} {{image_base}}/{{IMAGE}}:{{CHANNEL}}
    sudo podman push {{image_base}}/{{IMAGE}}:{{CHANNEL}}

disk-img IMAGE CHANNEL:
    mkdir -p build
    fallocate -l 10G build/{{IMAGE}}.img
    sudo podman run --privileged --pid=host --rm -v $PWD/build/{{IMAGE}}.img:/data/linux.img {{image_base}}/{{IMAGE}}:{{CHANNEL}} \
        bootc install to-disk --composefs-backend --generic-image --via-loopback /data/linux.img --filesystem btrfs --bootloader grub --wipe
    sudo chown $(whoami):$(whoami) build/{{IMAGE}}.img

run IMAGE PLATFORM:
    ./run.sh build/{{IMAGE}}.img {{PLATFORM}}