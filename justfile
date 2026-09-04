image_base := "quay.io/bensku/servuri-linux"

build-prep IMAGE:
    sudo podman build --build-arg IMAGE_BASE="{{image_base}}/prep" -t {{image_base}}/prep/{{IMAGE}} -f images/{{IMAGE}}/Containerfile .

build IMAGE:
    sudo podman build --build-arg IMAGE_BASE="{{image_base}}/prep" -t {{image_base}}/prep/{{IMAGE}} -f images/{{IMAGE}}/Containerfile .
    sudo podman build --build-arg PREP_IMAGE="{{image_base}}/prep/{{IMAGE}}" -t {{image_base}}/{{IMAGE}} -f images/_finalize/Containerfile .

build-all: && (build-prep "base") (build-prep "server-base") (build "server")

push IMAGE CHANNEL:
    sudo podman tag {{image_base}}/{{IMAGE}} {{image_base}}/{{IMAGE}}:{{CHANNEL}}
    sudo podman push {{image_base}}/{{IMAGE}}:{{CHANNEL}}

disk-img IMAGE CHANNEL:
    mkdir -p build
    fallocate -l 10G build/{{IMAGE}}.img
    sudo podman run --privileged --pid=host --rm -v $PWD/build/{{IMAGE}}.img:/data/linux.img {{image_base}}/{{IMAGE}}:{{CHANNEL}} \
        bootc install to-disk --composefs-backend --generic-image --via-loopback /data/linux.img --filesystem btrfs --bootloader grub --wipe
    sudo chown $(whoami):$(whoami) build/{{IMAGE}}.img
    zstd --compress --force build/{{IMAGE}}.img
    qemu-img convert -f raw -O qcow2 build/{{IMAGE}}.img build/{{IMAGE}}.qcow2

run IMAGE PLATFORM:
    ./run.sh build/{{IMAGE}}.img {{PLATFORM}}

hetzner-upload IMAGE:
    hcloud-upload-image upload --image-path build/{{IMAGE}}.img.zst --compression zstd \
        --description "servuri-linux {{IMAGE}}" --location hel1 --architecture x86