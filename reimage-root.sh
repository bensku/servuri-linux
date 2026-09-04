#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

usage() {
  cat <<'USAGE'
Usage:
  reimage-root.sh --url URL --target /dev/DISK \
      (--sha256 HEX | --sha256-url URL) [options]

Required:
  --url URL              Direct URL of a .zst-compressed raw disk image.
  --target DEV           Whole physical disk containing the current LVM root PV.
  --sha256 HEX           SHA-256 of the COMPRESSED .zst object.
    or
  --sha256-url URL       URL of a sha256sum-style file; first field is used.

Options:
  --retries N            Full-image attempts in RAM environment (default: 2).
  --connect-timeout SEC  Full-image connection timeout (default: 20).
  --stall-time SEC       Abort if below --stall-speed this long (default: 120).
  --stall-speed BPS      Minimum sustained transfer rate (default: 1024).
  --transfer-timeout SEC Maximum time for one full image transfer (default: 21600).
  --allow-http           Permit plain HTTP. HTTPS is required by default.
  --skip-head-check      Skip HTTP HEAD checks (both before and after shutdown).
  --yes                  Noninteractive destructive confirmation.
  -h, --help             Show this help.

Safety/model assumptions:
  * PID 1 is systemd.
  * /run is tmpfs.
  * Root is an ordinary LVM LV in a single local, complete VG.
  * The root VG has exactly one PV, on --target.
  * All LV segments in that VG are linear (no thin/cache/snapshot/RAID/etc.).
  * The LVM PV is directly on a disk or partition (no mdraid/dm-crypt beneath it).
  * Other ordinary partitions on --target (e.g. EFI and /boot) are fine.
  * A full validation download is performed before destructive confirmation.

The script does NOT overwrite the live root directly. It installs a small
shutdown environment in /run/initramfs and asks systemd to reboot normally.
During shutdown, systemd kills userspace and pivots into that RAM environment;
there the old root is unmounted, the VG is deactivated, and only then is the
raw disk image streamed onto --target.
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
trim() { awk '{$1=$1; print}' <<<"$*"; }

URL=
TARGET=
EXPECTED_SHA256=
SHA256_URL=
RETRIES=2
CONNECT_TIMEOUT=20
STALL_TIME=120
STALL_SPEED=1024
TRANSFER_TIMEOUT=21600
ALLOW_HTTP=0
SKIP_HEAD=0
ASSUME_YES=0

while (($#)); do
  case "$1" in
    --url)             URL=${2:?}; shift 2 ;;
    --target)          TARGET=${2:?}; shift 2 ;;
    --sha256)          EXPECTED_SHA256=${2:?}; shift 2 ;;
    --sha256-url)      SHA256_URL=${2:?}; shift 2 ;;
    --retries)         RETRIES=${2:?}; shift 2 ;;
    --connect-timeout) CONNECT_TIMEOUT=${2:?}; shift 2 ;;
    --stall-time)      STALL_TIME=${2:?}; shift 2 ;;
    --stall-speed)     STALL_SPEED=${2:?}; shift 2 ;;
    --transfer-timeout) TRANSFER_TIMEOUT=${2:?}; shift 2 ;;
    --allow-http)      ALLOW_HTTP=1; shift ;;
    --skip-head-check) SKIP_HEAD=1; shift ;;
    --yes)             ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root"
[[ -n $URL && -n $TARGET ]] || { usage >&2; exit 2; }
[[ -n $EXPECTED_SHA256 || -n $SHA256_URL ]] || die "provide --sha256 or --sha256-url"
[[ ! ( -n $EXPECTED_SHA256 && -n $SHA256_URL ) ]] || die "use only one of --sha256 and --sha256-url"
[[ $RETRIES =~ ^[1-9][0-9]*$ ]] || die "--retries must be a positive integer"
[[ $CONNECT_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "--connect-timeout must be a positive integer"
[[ $STALL_TIME =~ ^[1-9][0-9]*$ ]] || die "--stall-time must be a positive integer"
[[ $STALL_SPEED =~ ^[1-9][0-9]*$ ]] || die "--stall-speed must be a positive integer"
[[ $TRANSFER_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "--transfer-timeout must be a positive integer"

for c in \
  systemctl curl zstd dd tee sha256sum sync blockdev mount umount mountpoint \
  lsblk findmnt swapoff getent readlink ldd cp mkdir awk grep sed head \
  chmod rm mv chroot env ip lvs pvs vgs vgchange stat swapon mktemp mkfifo wc; do
  need "$c"
done

# This design relies on systemd-shutdown's exitrd support. It intentionally
# does not try to pivot from an arbitrary SSH/systemd service mount namespace.
[[ -d /run/systemd/system ]] || die "PID 1 does not appear to be systemd"
PID1_EXE=$(readlink -f /proc/1/exe 2>/dev/null || true)
[[ ${PID1_EXE##*/} == systemd ]] || die "PID 1 is not systemd ($PID1_EXE)"

RUN_FS=$(findmnt -n -o FSTYPE /run 2>/dev/null || true)
[[ $RUN_FS == tmpfs ]] || die "/run must be tmpfs; found '$RUN_FS'"

[[ -w /proc/sysrq-trigger ]] || die "/proc/sysrq-trigger is not writable; hard-reboot fallback unavailable"

TARGET=$(readlink -f -- "$TARGET")
[[ -b $TARGET ]] || die "target is not a block device: $TARGET"
[[ $(lsblk -dnro TYPE "$TARGET") == disk ]] || die "target must be a whole disk: $TARGET"

ROOTSRC=$(findmnt -n -o SOURCE /)
ROOTSRC=${ROOTSRC%%\[*}
ROOTDEV=$(readlink -f -- "$ROOTSRC")
[[ -b $ROOTDEV ]] || die "root filesystem is not backed by an identifiable block device: $ROOTSRC"
ROOTTYPE=$(lsblk -dnro TYPE "$ROOTDEV")
[[ $ROOTTYPE == lvm ]] || die "this version expects an LVM root; root device type is '$ROOTTYPE'"

# Find the LV by comparing canonical lv_path targets with the mounted root dm device.
VG=
LVNAME=
while IFS='|' read -r vg lv path; do
  vg=$(trim "$vg")
  lv=$(trim "$lv")
  path=$(trim "$path")
  [[ -n $path && -e $path ]] || continue
  if [[ $(readlink -f -- "$path") == "$ROOTDEV" ]]; then
    VG=$vg
    LVNAME=$lv
    break
  fi
done < <(lvs --noheadings --separator '|' -o vg_name,lv_name,lv_path)
[[ -n $VG && -n $LVNAME ]] || die "could not map root device $ROOTDEV back to an LVM LV"
ROOTLV="$VG/$LVNAME"

VGATTR=$(trim "$(vgs --noheadings -o vg_attr "$VG")")
[[ ${#VGATTR} -ge 6 ]] || die "could not read VG attributes for $VG"
[[ ${VGATTR:3:1} != p ]] || die "root VG $VG is partial/degraded; refusing"
case ${VGATTR:5:1} in
  c|s) die "root VG $VG is clustered/shared; refusing" ;;
esac

# Every LV segment in this VG must be plain linear. This permits normal root,
# swap, /var, etc. LVs while refusing snapshots/thin/cache/RAID/mirror stacks.
while IFS='|' read -r lv seg; do
  lv=$(trim "$lv")
  seg=$(trim "$seg")
  [[ -z $lv ]] && continue
  [[ $seg == linear ]] || die "unsupported LV segment in $VG/$lv: '$seg' (only linear is allowed)"
done < <(lvs --segments --noheadings --separator '|' -o lv_name,segtype "$VG")

# Root VG must have exactly one PV.
declare -a ROOT_PVS=()
while IFS='|' read -r pv vg; do
  pv=$(trim "$pv")
  vg=$(trim "$vg")
  [[ $vg == "$VG" ]] || continue
  [[ -n $pv ]] && ROOT_PVS+=("$(readlink -f -- "$pv")")
done < <(pvs --noheadings --separator '|' -o pv_name,vg_name)
((${#ROOT_PVS[@]} == 1)) || die "root VG $VG has ${#ROOT_PVS[@]} PVs; exactly one is required"
PVDEV=${ROOT_PVS[0]}
[[ -b $PVDEV ]] || die "root PV is not an accessible block device: $PVDEV"

PVTYPE=$(lsblk -dnro TYPE "$PVDEV")
case "$PVTYPE" in
  disk|part) ;;
  *) die "unsupported layer beneath LVM PV: $PVDEV has type '$PVTYPE'" ;;
esac
while read -r t; do
  case "$t" in disk|part) ;; *) die "unsupported device type '$t' beneath LVM PV $PVDEV" ;; esac
done < <(lsblk -snro TYPE "$PVDEV")

if ! lsblk -snrpo PATH "$PVDEV" | grep -Fxq -- "$TARGET"; then
  die "target $TARGET is not an ancestor of root VG PV $PVDEV"
fi

# Refuse any other PV/VG living on the target disk.
while IFS='|' read -r pv vg; do
  pv=$(trim "$pv")
  vg=$(trim "$vg")
  [[ -n $pv && -b $pv ]] || continue
  cpv=$(readlink -f -- "$pv")
  if lsblk -snrpo PATH "$cpv" | grep -Fxq -- "$TARGET"; then
    [[ $vg == "$VG" ]] || die "target contains another LVM VG/PV: $cpv belongs to '${vg:-<no VG>}'"
  fi
done < <(pvs --noheadings --separator '|' -o pv_name,vg_name)

# On the target, only ordinary disk/partition nodes and LVM are accepted.
# Any crypt/md/raid/multipath/etc. descendant is a refusal.
while read -r t; do
  case "$t" in disk|part|lvm) ;; *) die "unsupported active device type '$t' somewhere on $TARGET" ;; esac
done < <(lsblk -nro TYPE "$TARGET")

TARGET_SIZE=$(lsblk -bdnro SIZE "$TARGET")
[[ $TARGET_SIZE =~ ^[1-9][0-9]*$ ]] || die "could not determine a valid size for $TARGET"
TARGET_MODEL=$(trim "$(lsblk -dnro MODEL "$TARGET" 2>/dev/null || true)")
TARGET_SERIAL=$(trim "$(lsblk -dnro SERIAL "$TARGET" 2>/dev/null || true)")

# Parse a restricted direct URL so shutdown does not depend on DNS.
if [[ $URL =~ ^(https?)://([^/:@]+)(:([0-9]+))?(/.*)?$ ]]; then
  SCHEME=${BASH_REMATCH[1]}
  HOST=${BASH_REMATCH[2]}
  PORT=${BASH_REMATCH[4]:-}
else
  die "URL must be direct http(s) with hostname/IPv4 literal; userinfo/IPv6 literals are unsupported"
fi
[[ $SCHEME == https || $ALLOW_HTTP -eq 1 ]] || die "plain HTTP refused; use HTTPS or --allow-http"
if [[ -z $PORT ]]; then
  [[ $SCHEME == https ]] && PORT=443 || PORT=80
fi
IP=$(getent ahostsv4 "$HOST" | awk 'NR==1 {print $1}')
[[ -n $IP ]] || die "could not resolve $HOST to IPv4"

CURL_PROTO="=$SCHEME"
if [[ -n $SHA256_URL ]]; then
  HASH_PROTO='=https'
  (( ALLOW_HTTP )) && HASH_PROTO='=https,http'
  EXPECTED_SHA256=$(curl -fsSL --proto "$HASH_PROTO" --connect-timeout 10 --max-time 30 "$SHA256_URL" | awk 'NR==1 {print $1}')
fi
EXPECTED_SHA256=${EXPECTED_SHA256,,}
[[ $EXPECTED_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256: expected 64 hex digits"

# Apply the same finite transfer bounds to the validation pass and the later
# destructive pass. --speed-time/--speed-limit catches a connected transfer
# that stops making useful progress; --max-time also supplies a hard ceiling.
CURL_IMAGE_ARGS=(
  --fail --show-error --silent --noproxy '*'
  --proto "$CURL_PROTO" --resolve "$HOST:$PORT:$IP"
  --connect-timeout "$CONNECT_TIMEOUT"
  --speed-limit "$STALL_SPEED" --speed-time "$STALL_TIME"
  --max-time "$TRANSFER_TIMEOUT"
)

if (( ! SKIP_HEAD )); then
  HTTP_CODE=$(curl -sS -I -o /dev/null \
    --proto "$CURL_PROTO" --resolve "$HOST:$PORT:$IP" \
    --connect-timeout 10 --max-time 30 -w '%{http_code}' "$URL") || die "HEAD preflight failed"
  [[ $HTTP_CODE =~ ^2[0-9][0-9]$ ]] || die "HEAD preflight returned HTTP $HTTP_CODE; use a direct URL or --skip-head-check"
fi

# Capture enough IPv4 state to recreate the route after networking services
# have been stopped by the normal systemd shutdown.
ROUTE_LINE=$(ip -4 route get "$IP" 2>/dev/null | head -n1) || die "no IPv4 route to image server $IP"
IFACE=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$ROUTE_LINE")
SRC_IP=$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<<"$ROUTE_LINE")
GATEWAY=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$ROUTE_LINE")
[[ -n $IFACE && $IFACE != lo ]] || die "could not identify non-loopback interface for $IP"
[[ -n $SRC_IP ]] || die "could not identify source IPv4 address for $IP"
SRC_CIDR=$(ip -o -4 addr show dev "$IFACE" | awk -v s="$SRC_IP" '{split($4,a,"/"); if(a[1]==s){print $4; exit}}')
[[ -n $SRC_CIDR ]] || die "could not determine prefix length for source address $SRC_IP on $IFACE"
MTU=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null || true)
[[ $MTU =~ ^[0-9]+$ ]] || MTU=1500

# Prove the exact compressed artifact and its decompressed byte count before
# asking for permission to destroy anything. No image data is retained: both
# hash calculation and decompression are streaming, and /run holds only a FIFO
# plus two tiny result files.
prevalidate_image() (
  local validate_dir hash_pid hash_rc actual raw_size
  local -a pst

  validate_dir=$(mktemp -d /run/reimage-validate.XXXXXX) || die "could not create validation workspace in /run"
  trap 'rm -rf -- "$validate_dir"' EXIT
  mkfifo "$validate_dir/compressed.pipe" || die "could not create validation FIFO"
  sha256sum < "$validate_dir/compressed.pipe" > "$validate_dir/compressed.sha256" &
  hash_pid=$!

  set +e
  curl "${CURL_IMAGE_ARGS[@]}" "$URL" \
    | tee "$validate_dir/compressed.pipe" \
    | zstd -d -c \
    | wc -c > "$validate_dir/decompressed.size"
  pst=("${PIPESTATUS[@]}")
  wait "$hash_pid"
  hash_rc=$?
  set -e

  actual=
  read -r actual _ < "$validate_dir/compressed.sha256" || true
  actual=${actual,,}
  raw_size=$(awk '{$1=$1; print}' "$validate_dir/decompressed.size" 2>/dev/null || true)

  if [[ ${pst[0]} -ne 0 || ${pst[1]} -ne 0 || ${pst[2]} -ne 0 || ${pst[3]} -ne 0 || $hash_rc -ne 0 ]]; then
    die "full image validation failed (pipeline=${pst[*]} hash_rc=$hash_rc)"
  fi
  [[ $actual == "$EXPECTED_SHA256" ]] || die "compressed image SHA-256 mismatch: expected $EXPECTED_SHA256, got ${actual:-missing}"
  [[ $raw_size =~ ^[1-9][0-9]*$ ]] || die "image decompressed to an invalid byte count: '${raw_size:-missing}'"
  (( raw_size <= TARGET_SIZE )) || die "decompressed image is $raw_size bytes, larger than target ($TARGET_SIZE bytes)"

  printf '%s\n' "$raw_size"
)

printf 'Pre-validating the complete image (streaming download; disk is untouched)...\n'
DECOMPRESSED_SIZE=$(prevalidate_image)
printf 'Validated compressed SHA-256, zstd stream, and %s decompressed bytes.\n' "$DECOMPRESSED_SIZE"

printf '\nAbout to schedule destructive reimage through systemd shutdown exitrd.\n'
printf '  target:      %s\n' "$TARGET"
printf '  size:        %s bytes\n' "$TARGET_SIZE"
printf '  model:       %s\n' "${TARGET_MODEL:-unknown}"
printf '  serial:      %s\n' "${TARGET_SERIAL:-unknown}"
printf '  root LV:     %s (%s)\n' "$ROOTLV" "$ROOTDEV"
printf '  root VG/PV:  %s -> %s\n' "$VG" "$PVDEV"
printf '  image size:  %s bytes (decompressed)\n' "$DECOMPRESSED_SIZE"
printf '  image host:  %s:%s (%s)\n' "$HOST" "$PORT" "$IP"
printf '  network:     %s %s%s\n' "$IFACE" "$SRC_CIDR" "${GATEWAY:+ via $GATEWAY}"
printf '  sha256:      %s\n\n' "$EXPECTED_SHA256"

if (( ! ASSUME_YES )); then
  printf 'Type exactly: ERASE %s\n> ' "$TARGET"
  read -r answer
  [[ $answer == "ERASE $TARGET" ]] || die "confirmation did not match"
fi

EXITRD=/run/initramfs
WORK=$EXITRD/reimage
OLD_SHUTDOWN_BACKUP=
TRIGGERED=0
SWAP_DISABLED=0
declare -a QUIESCED_EXITRD_PROVIDERS=()

# Ubuntu's finalrd.service (and dracut-shutdown.service, when dracut is used)
# normally generates /run/initramfs from ExecStop during shutdown. Stop any
# active generator now, let it finish once, and install our hook afterward so
# it cannot replace /run/initramfs/shutdown during the upcoming reboot.
quiesce_shutdown_exitrd_providers() {
  local unit load_state active_state

  for unit in finalrd.service dracut-shutdown.service; do
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || true)
    [[ $load_state == loaded ]] || continue

    active_state=$(systemctl show --property=ActiveState --value "$unit") \
      || die "could not query shutdown exitrd provider $unit"
    case "$active_state" in
      active|activating|reloading|deactivating)
        echo "quiescing shutdown exitrd provider: $unit"
        QUIESCED_EXITRD_PROVIDERS+=("$unit")
        systemctl stop "$unit" || die "could not stop shutdown exitrd provider $unit"
        active_state=$(systemctl show --property=ActiveState --value "$unit") \
          || die "could not verify shutdown exitrd provider $unit"
        [[ $active_state == inactive ]] \
          || die "shutdown exitrd provider $unit remained $active_state after stop"
        ;;
      inactive|failed) ;;
      *) die "unexpected ActiveState '$active_state' for shutdown exitrd provider $unit" ;;
    esac
  done
}

cleanup() {
  rc=$?
  if (( ! TRIGGERED )); then
    if (( SWAP_DISABLED )); then
      swapon -a >/dev/null 2>&1 || true
    fi
    # Remove temporary preflight mounts if an earlier command failed.
    umount "$EXITRD/dev"  >/dev/null 2>&1 || true
    umount "$EXITRD/proc" >/dev/null 2>&1 || true
    umount "$EXITRD/sys"  >/dev/null 2>&1 || true
    rm -rf "$WORK" >/dev/null 2>&1 || true
    if [[ -n $OLD_SHUTDOWN_BACKUP && -e $OLD_SHUTDOWN_BACKUP ]]; then
      mv -f "$OLD_SHUTDOWN_BACKUP" "$EXITRD/shutdown" >/dev/null 2>&1 || true
    elif [[ -f $EXITRD/shutdown && $(head -n1 "$EXITRD/shutdown" 2>/dev/null || true) == '#!/reimage/tool/bash' ]]; then
      rm -f "$EXITRD/shutdown" >/dev/null 2>&1 || true
    fi
    # Re-arm providers if preparation was abandoned and this OS keeps running.
    for unit in "${QUIESCED_EXITRD_PROVIDERS[@]}"; do
      systemctl start "$unit" >/dev/null 2>&1 || true
    done
  fi
  exit "$rc"
}
trap cleanup EXIT

quiesce_shutdown_exitrd_providers

mkdir -p "$EXITRD" "$WORK/tool" "$EXITRD/dev" "$EXITRD/proc" "$EXITRD/sys" "$EXITRD/run" "$EXITRD/etc"

if [[ -e $EXITRD/shutdown ]]; then
  OLD_SHUTDOWN_BACKUP="$EXITRD/shutdown.reimage-backup.$$"
  mv "$EXITRD/shutdown" "$OLD_SHUTDOWN_BACKUP"
fi

copy_one_binary() {
  local name=$1 src lib
  src=$(command -v "$name") || die "cannot locate $name"
  src=$(readlink -f -- "$src")
  cp -L -- "$src" "$WORK/tool/$name"

  while read -r lib; do
    [[ -e $lib ]] || continue
    mkdir -p "$EXITRD$(dirname "$lib")"
    cp -L -- "$lib" "$EXITRD$lib"
  done < <(ldd "$src" 2>/dev/null | awk '/=> \/[^ ]+/ {print $3} /^\// {print $1}')
}

for c in bash curl zstd dd tee sha256sum sync blockdev mount umount mountpoint lsblk \
         mkfifo rm sleep ip vgchange; do
  copy_one_binary "$c"
done

# TLS trust/config and OpenSSL provider modules.
for p in /etc/ssl /etc/pki /etc/crypto-policies /etc/gnutls; do
  if [[ -e $p ]]; then
    mkdir -p "$EXITRD$(dirname "$p")"
    cp -aL -- "$p" "$EXITRD$p"
  fi
done
for p in /usr/lib*/ossl-modules /usr/lib/*/ossl-modules /lib*/ossl-modules /lib/*/ossl-modules; do
  [[ -e $p ]] || continue
  mkdir -p "$EXITRD$(dirname "$p")"
  cp -aL -- "$p" "$EXITRD$p"
done

# LVM config and optional runtime-loaded device-mapper/LVM plugins.
if [[ -d /etc/lvm ]]; then
  rm -rf "$EXITRD/etc/lvm"
  cp -aL /etc/lvm "$EXITRD/etc/lvm"
fi
for p in /usr/lib*/device-mapper /usr/lib/*/device-mapper /lib*/device-mapper /lib/*/device-mapper \
         /usr/lib*/lvm2 /usr/lib/*/lvm2 /lib*/lvm2 /lib/*/lvm2; do
  [[ -e $p ]] || continue
  mkdir -p "$EXITRD$(dirname "$p")"
  cp -aL -- "$p" "$EXITRD$p"
done
mkdir -p "$EXITRD/run/lock/lvm" "$EXITRD/run/lvm"

cat > "$WORK/config" <<EOF_CFG
URL=$(printf '%q' "$URL")
TARGET=$(printf '%q' "$TARGET")
EXPECTED_SHA256=$(printf '%q' "$EXPECTED_SHA256")
SCHEME=$(printf '%q' "$SCHEME")
HOST=$(printf '%q' "$HOST")
PORT=$(printf '%q' "$PORT")
IP=$(printf '%q' "$IP")
RETRIES=$(printf '%q' "$RETRIES")
CONNECT_TIMEOUT=$(printf '%q' "$CONNECT_TIMEOUT")
STALL_TIME=$(printf '%q' "$STALL_TIME")
STALL_SPEED=$(printf '%q' "$STALL_SPEED")
TRANSFER_TIMEOUT=$(printf '%q' "$TRANSFER_TIMEOUT")
DECOMPRESSED_SIZE=$(printf '%q' "$DECOMPRESSED_SIZE")
SKIP_HEAD=$(printf '%q' "$SKIP_HEAD")
VG=$(printf '%q' "$VG")
PVDEV=$(printf '%q' "$PVDEV")
IFACE=$(printf '%q' "$IFACE")
SRC_IP=$(printf '%q' "$SRC_IP")
SRC_CIDR=$(printf '%q' "$SRC_CIDR")
GATEWAY=$(printf '%q' "$GATEWAY")
MTU=$(printf '%q' "$MTU")
EOF_CFG
chmod 0600 "$WORK/config"

cat > "$WORK/shutdown-stage" <<'EOF_STAGE'
set -Eeuo pipefail
source /reimage/config
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
unset SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE LD_LIBRARY_PATH LD_PRELOAD

log() {
  if [[ -w /dev/console ]]; then
    echo "reimage: $*" >/dev/console
  else
    echo "reimage: $*" >&2
  fi
}

stop_watchdog_pet() {
  local pet_pid=${WATCHDOG_PET_PID:-}

  if [[ $pet_pid =~ ^[1-9][0-9]*$ ]]; then
    kill "$pet_pid" 2>/dev/null || true
    wait "$pet_pid" 2>/dev/null || true
    WATCHDOG_PET_PID=
  fi
  # Do not use the magic-close byte: if the immediate sysrq reboot fails, the
  # still-armed watchdog remains the final reboot fallback.
  exec 9>&- 2>/dev/null || true
}

hard_reboot() {
  stop_watchdog_pet
  /reimage/tool/sync 2>/dev/null || true
  echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
  echo b > /proc/sysrq-trigger 2>/dev/null || true
  while :; do /reimage/tool/sleep 3600; done
}

prewrite_fail() {
  log "FAILED before raw disk writing; original disk was not overwritten; rebooting"
  hard_reboot
}

# systemd-shutdown deliberately leaves RebootWatchdogSec armed when it execs
# an exitrd /shutdown program. Reopen the watchdog and keep feeding it for the
# potentially long validation/write retry window. WATCHDOG_USEC and an optional
# WATCHDOG_DEVICE are inherited from systemd-shutdown.
watchdog_pet_loop() {
  local interval=$1

  while :; do
    /reimage/tool/sleep "$interval" || {
      log "watchdog pet timer failed; forcing immediate reboot"
      hard_reboot
    }
    printf '\0' >&9 || {
      log "watchdog keepalive write failed; forcing immediate reboot"
      hard_reboot
    }
  done
}

start_watchdog_pet() {
  local watchdog_usec=${WATCHDOG_USEC:-0}
  local requested_usec device opened=0 watchdog_name timeout_path
  local actual_timeout actual_usec interval_usec interval
  local -a candidates

  [[ $watchdog_usec =~ ^[0-9]+$ ]] || prewrite_fail
  [[ ! $watchdog_usec =~ ^0+$ ]] || return 0
  if ((${#watchdog_usec} > 18)); then
    # USEC_INFINITY (RebootWatchdogSec=default) does not fit Bash's signed
    # arithmetic. Use a conservative fallback until sysfs tells us the actual
    # programmed hardware timeout below.
    requested_usec=1000000
  else
    requested_usec=$((10#$watchdog_usec))
  fi

  if [[ -n ${WATCHDOG_DEVICE:-} ]]; then
    candidates=("$WATCHDOG_DEVICE")
  else
    candidates=(/dev/watchdog0 /dev/watchdog)
  fi

  for device in "${candidates[@]}"; do
    [[ -c $device ]] || continue
    if exec 9>"$device"; then
      opened=1
      break
    fi
    log "could not reopen armed watchdog device $device"
    prewrite_fail
  done

  if (( ! opened )); then
    # systemd can pass its configured reboot-watchdog interval even when the
    # kernel exposes no watchdog device, in which case nothing was armed.
    log "WATCHDOG_USEC is set but no watchdog device is present; continuing"
    return 0
  fi

  printf '\0' >&9 || prewrite_fail
  watchdog_name=${device##*/}
  [[ $watchdog_name == watchdog ]] && watchdog_name=watchdog0
  timeout_path="/sys/class/watchdog/$watchdog_name/timeout"
  actual_timeout=
  if [[ -r $timeout_path ]]; then
    read -r actual_timeout < "$timeout_path" || actual_timeout=
  fi
  if [[ $actual_timeout =~ ^[1-9][0-9]*$ ]]; then
    actual_usec=$((actual_timeout * 1000000))
    (( actual_usec < requested_usec )) && requested_usec=$actual_usec
  else
    # Without a readable live timeout, feed at least four times per second;
    # Linux watchdog timeouts are expressed as positive whole seconds.
    (( requested_usec > 1000000 )) && requested_usec=1000000
  fi

  interval_usec=$((requested_usec / 4))
  (( interval_usec < 1000 )) && interval_usec=1000
  (( interval_usec > 30000000 )) && interval_usec=30000000
  printf -v interval '%d.%06d' "$((interval_usec / 1000000))" "$((interval_usec % 1000000))"
  watchdog_pet_loop "$interval" &
  WATCHDOG_PET_PID=$!
  log "reboot watchdog active on $device; feeding every ${interval}s (pid $WATCHDOG_PET_PID)"
}

# systemd normally moves these API filesystems into the exitrd. Mount them if
# a particular version/environment did not.
/reimage/tool/mountpoint -q /proc || /reimage/tool/mount -t proc proc /proc || prewrite_fail
/reimage/tool/mountpoint -q /sys  || /reimage/tool/mount -t sysfs sysfs /sys || prewrite_fail
/reimage/tool/mountpoint -q /dev  || /reimage/tool/mount -t devtmpfs devtmpfs /dev || prewrite_fail

start_watchdog_pet
log "entered systemd shutdown RAM environment"

# Recreate the network route because networkd/NetworkManager may have removed
# addresses/routes during normal shutdown.
/reimage/tool/ip link set dev "$IFACE" up || prewrite_fail
/reimage/tool/ip link set dev "$IFACE" mtu "$MTU" 2>/dev/null || true
/reimage/tool/ip addr replace "$SRC_CIDR" dev "$IFACE" || prewrite_fail
if [[ -n $GATEWAY ]]; then
  /reimage/tool/ip route replace "$IP/32" via "$GATEWAY" dev "$IFACE" src "$SRC_IP" onlink || prewrite_fail
else
  /reimage/tool/ip route replace "$IP/32" dev "$IFACE" src "$SRC_IP" || prewrite_fail
fi

# Verify connectivity from the exact environment that will perform the write.
if (( ! SKIP_HEAD )); then
  /reimage/tool/curl --fail --silent --show-error --head --noproxy '*' \
    --proto "=$SCHEME" --resolve "$HOST:$PORT:$IP" \
    --connect-timeout 10 --max-time 30 "$URL" >/dev/null || prewrite_fail
fi

# We are now PID 1 after systemd-shutdown switched root to /run/initramfs and
# exec'd /shutdown. All normal userspace has already been killed. Strictly
# unmount the old root tree; do NOT use lazy unmount here.
/reimage/tool/sync || prewrite_fail
if /reimage/tool/mountpoint -q /oldroot; then
  /reimage/tool/umount -R /oldroot || prewrite_fail
fi
/reimage/tool/mountpoint -q /oldroot && prewrite_fail

# Deactivate the root VG after all filesystems using it have really gone away.
# udev is no longer running, and this process is the only LVM actor, so do not
# wait for udev synchronization or LVM locking daemons.
/reimage/tool/vgchange -an --noudevsync --nolocking "$VG" || prewrite_fail

# The target must now have no active LVM/dm/md/etc descendants at all.
while read -r t; do
  case "$t" in
    disk|part) ;;
    *) log "active '$t' device remains below $TARGET after VG deactivation"; prewrite_fail ;;
  esac
done < <(/reimage/tool/lsblk -nro TYPE "$TARGET")

/reimage/tool/blockdev --flushbufs "$TARGET" 2>/dev/null || true

# From this line onward the old installation is expendable.
log "starting destructive write of prevalidated $DECOMPRESSED_SIZE-byte image"
ok=0
for ((attempt=1; attempt<=RETRIES; attempt++)); do
  log "write attempt $attempt/$RETRIES"
  /reimage/tool/rm -f /reimage/compressed.sha256.pipe /reimage/compressed.sha256.actual
  /reimage/tool/mkfifo /reimage/compressed.sha256.pipe
  /reimage/tool/sha256sum < /reimage/compressed.sha256.pipe > /reimage/compressed.sha256.actual &
  HPID=$!

  set +e
  /reimage/tool/curl --fail --show-error --silent --noproxy '*' \
      --proto "=$SCHEME" --resolve "$HOST:$PORT:$IP" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --speed-limit "$STALL_SPEED" --speed-time "$STALL_TIME" \
      --max-time "$TRANSFER_TIMEOUT" "$URL" \
    | /reimage/tool/tee /reimage/compressed.sha256.pipe \
    | /reimage/tool/zstd -d -c \
    | /reimage/tool/dd of="$TARGET" bs=16M iflag=fullblock conv=fsync status=progress
  pst=("${PIPESTATUS[@]}")
  wait "$HPID"
  hst=$?
  set -e

  actual=
  read -r actual _ < /reimage/compressed.sha256.actual || true
  actual=${actual,,}

  if [[ ${pst[0]} -eq 0 && ${pst[1]} -eq 0 && ${pst[2]} -eq 0 && ${pst[3]} -eq 0 && \
        $hst -eq 0 && $actual == "$EXPECTED_SHA256" ]]; then
    ok=1
    break
  fi

  log "attempt $attempt failed; pipeline=${pst[*]} hash_rc=$hst"
  log "expected=$EXPECTED_SHA256 actual=${actual:-missing}"
  /reimage/tool/sleep 5
done

if (( ! ok )); then
  log "FAILED after $RETRIES attempts; disk is partial/unknown; remaining alive in RAM for panel reset"
  while :; do /reimage/tool/sleep 3600; done
fi

/reimage/tool/sync
/reimage/tool/blockdev --flushbufs "$TARGET" 2>/dev/null || true
log "image written and compressed SHA-256 verified; rebooting"
/reimage/tool/sleep 2
hard_reboot
EOF_STAGE
chmod 0700 "$WORK/shutdown-stage"

cat > "$EXITRD/shutdown" <<'EOF_SHUTDOWN'
#!/reimage/tool/bash
exec /reimage/tool/bash /reimage/shutdown-stage "$@"
EOF_SHUTDOWN
chmod 0700 "$EXITRD/shutdown"

# Temporarily bind API filesystems only for a realistic chroot preflight, then
# remove the binds; systemd-shutdown will set them up properly when it pivots.
mount --bind /dev  "$EXITRD/dev"
mount --bind /proc "$EXITRD/proc"
mount --bind /sys  "$EXITRD/sys"

PRECHECK_RC=0
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    -u NO_PROXY -u no_proxy -u SSL_CERT_FILE -u SSL_CERT_DIR -u CURL_CA_BUNDLE \
    -u LD_LIBRARY_PATH -u LD_PRELOAD \
  chroot "$EXITRD" /reimage/tool/bash -c '
    set -Eeuo pipefail
    source /reimage/config
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy
    unset SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE LD_LIBRARY_PATH LD_PRELOAD
    /reimage/tool/ip -4 route get "$IP" >/dev/null
    /reimage/tool/lsblk "$TARGET" >/dev/null
    /reimage/tool/vgchange --version >/dev/null
    /reimage/tool/zstd --version >/dev/null
    /reimage/tool/sleep 0.001
    /reimage/tool/dd if=/dev/zero of=/reimage/dd.option-test bs=512 count=1 iflag=fullblock conv=fsync status=none
    /reimage/tool/rm -f /reimage/dd.option-test
    if (( ! SKIP_HEAD )); then
      /reimage/tool/curl --fail --silent --show-error --head --noproxy "*" \
        --proto "=$SCHEME" --resolve "$HOST:$PORT:$IP" \
        --connect-timeout 10 --max-time 30 "$URL" >/dev/null
    else
      /reimage/tool/curl --version >/dev/null
    fi
  ' || PRECHECK_RC=$?

umount "$EXITRD/sys"
umount "$EXITRD/proc"
umount "$EXITRD/dev"
(( PRECHECK_RC == 0 )) || die "RAM shutdown environment preflight failed"

# Disable swap before beginning shutdown. This both catches insufficient RAM
# early and avoids a swapfile/LV remaining active while systemd tears storage down.
echo "disabling all swap"
swapoff -a || die "could not disable all swap"
SWAP_DISABLED=1
sync

# Final sanity checks: systemd must still see our hook, and no generator that
# we stopped may have become active again and be poised to replace it.
[[ -x $EXITRD/shutdown ]] || die "exitrd shutdown hook disappeared"
[[ $(head -n1 "$EXITRD/shutdown" 2>/dev/null || true) == '#!/reimage/tool/bash' ]] \
  || die "exitrd shutdown hook was replaced after installation"
for unit in "${QUIESCED_EXITRD_PROVIDERS[@]}"; do
  active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)
  [[ $active_state == inactive ]] \
    || die "shutdown exitrd provider $unit became '$active_state' after being quiesced"
done

printf '\nPrepared /run/initramfs reimage environment. Starting normal systemd reboot.\n'
printf 'The SSH connection will close. Raw disk writing begins only after systemd has shut userspace down,\n'
printf 'pivoted into RAM, unmounted /oldroot, and deactivated VG %s.\n' "$VG"

# From here systemd owns the transition. Do NOT use --force: the normal shutdown
# path is what kills userspace and hands control to /run/initramfs/shutdown.
TRIGGERED=1
trap - EXIT
if ! systemctl reboot --no-wall; then
  TRIGGERED=0
  trap cleanup EXIT
  die "systemctl refused/failed to start the normal reboot"
fi

# systemctl normally returns after queuing the reboot. Keep this process inert
# until systemd kills it during shutdown.
while :; do sleep 3600; done
