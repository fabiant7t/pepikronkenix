#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo scripts/write-usb.sh <disk-image> <usb-block-device> [confirmation]

Example:
  sudo scripts/write-usb.sh result/nixos.img /dev/sdX pepikronkenix

This writes the pepikronkenix raw disk image to the USB device and creates an
ext4 partition labelled "models" after a fixed 16 GiB image area if that
filesystem does not already exist there. Existing model data in that fixed area
is preserved. ALL OTHER DATA ON THE DEVICE WILL BE DESTROYED.

Safety confirmation must be the literal word: pepikronkenix
EOF
}

IMAGE=${1:-}
USB=${2:-}
CONFIRMATION=${3:-${CONFIRM:-}}

if [[ -z "$IMAGE" || -z "$USB" ]]; then
  usage
  exit 2
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: this script must run as root because it writes block devices." >&2
  exit 1
fi

for tool in blockdev lsblk findmnt dd partprobe udevadm parted blkid mkfs.ext4 wipefs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' is missing." >&2
    exit 1
  fi
done

if ! command -v sgdisk >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: required tool 'sgdisk' is missing.
Install the gptfdisk package. It is needed to relocate the disk image's GPT
backup header to the end of the target USB device before adding the models
partition.
EOF
  exit 1
fi

if [[ "$CONFIRMATION" != "pepikronkenix" ]]; then
  usage
  echo >&2
  echo "ERROR: missing safety confirmation. Pass CONFIRM=pepikronkenix via make or the third argument." >&2
  exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "ERROR: disk image not found: $IMAGE" >&2
  exit 1
fi

if [[ ! -b "$USB" ]]; then
  echo "ERROR: USB block device not found: $USB" >&2
  exit 1
fi

case "$USB" in
  /dev/sd*|/dev/nvme*n*|/dev/mmcblk*|/dev/vd*|/dev/loop*) ;;
  *)
    echo "ERROR: '$USB' does not look like a whole block device." >&2
    echo "Use e.g. /dev/sdX, not /dev/sdX1." >&2
    exit 1
    ;;
esac

if lsblk -no TYPE "$USB" | head -n1 | grep -vq '^disk\|loop$'; then
  echo "ERROR: '$USB' does not appear to be a disk/loop device." >&2
  exit 1
fi

root_source=$(findmnt -n -o SOURCE / || true)
if [[ -n "$root_source" && "$root_source" == "$USB"* ]]; then
  echo "ERROR: refusing to write the device that appears to contain /." >&2
  exit 1
fi

cat >&2 <<EOF
About to destroy and rewrite:

$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$USB")

Image: $IMAGE
USB:   $USB
EOF

read -r -p "Type 'DESTROY $USB' to continue: " answer
if [[ "$answer" != "DESTROY $USB" ]]; then
  echo "Aborted." >&2
  exit 1
fi

# Unmount mounted partitions belonging to the device.
while read -r mountpoint; do
  [[ -z "$mountpoint" ]] && continue
  echo "Unmounting $mountpoint"
  umount "$mountpoint"
done < <(lsblk -nrpo MOUNTPOINTS "$USB" | sed '/^$/d' | tac)

image_bytes=$(stat -c %s "$IMAGE")
disk_bytes=$(blockdev --getsize64 "$USB")
reserved_mib=${PEPIKRONKENIX_IMAGE_RESERVED_MIB:-16384}
reserved_bytes=$(( reserved_mib * 1024 * 1024 ))

if (( image_bytes > reserved_bytes )); then
  echo "ERROR: disk image is too large for the reserved image area." >&2
  echo "Image size:    $image_bytes bytes" >&2
  echo "Reserved area: ${reserved_mib} MiB" >&2
  echo "Increase PEPIKRONKENIX_IMAGE_RESERVED_MIB or rebuild a smaller image." >&2
  exit 1
fi

if (( disk_bytes <= reserved_bytes + 512 * 1024 * 1024 )); then
  echo "ERROR: USB device must be at least about 512 MiB larger than the ${reserved_mib} MiB image area to hold the models partition." >&2
  exit 1
fi

fixed_start_sector=$(( reserved_bytes / 512 ))
existing_models=$(lsblk -nrpo NAME,LABEL,START "$USB" \
  | awk '$2 == "models" { print $1 ":" $3; exit }')
if [[ -n "$existing_models" ]]; then
  existing_models_part=${existing_models%%:*}
  existing_models_start=${existing_models##*:}
  if [[ "$existing_models_start" != "$fixed_start_sector" ]]; then
    cat >&2 <<EOF
ERROR: found an existing models partition at $existing_models_part, but it starts
at sector $existing_models_start instead of the fixed ${reserved_mib} MiB image
boundary at sector $fixed_start_sector.

Back up the models, remove/recreate the USB once with this writer, then future
writes can preserve the models filesystem.
EOF
    exit 1
  fi
fi

echo "Writing the disk image area. Existing model data after ${reserved_mib}MiB will not be touched."

if command -v pv >/dev/null 2>&1; then
  echo "Writing image with progress bar..."
  pv -s "$image_bytes" "$IMAGE" | dd of="$USB" bs=4M status=none conv=fsync
else
  echo "Writing image. Install 'pv' for a nicer progress bar."
  dd if="$IMAGE" of="$USB" bs=4M status=progress conv=fsync
fi
sync

partprobe "$USB" || true
udevadm settle || true
sleep 2

# The raw image contains a GPT sized for the fixed image area. After writing it
# to a larger USB device, move the GPT backup header to the real end of the
# device so a normal third partition can be added for models.
echo "Relocating GPT backup header to the end of $USB..."
sgdisk -e "$USB"
partprobe "$USB" || true
udevadm settle || true
sleep 2

start_mib=$reserved_mib
disk_mib=$(( disk_bytes / (1024 * 1024) ))

if (( disk_mib - start_mib < 512 )); then
  echo "ERROR: not enough free space remains for a useful models partition." >&2
  exit 1
fi

echo "Creating/restoring writable ext4 partition entry labelled 'models' from ${start_mib}MiB to end of disk..."
parted -s -a optimal "$USB" mkpart models ext4 "${start_mib}MiB" 100%
partprobe "$USB" || true
udevadm settle || true
sleep 2

models_part=$(lsblk -nrpo NAME,TYPE,START "$USB" \
  | awk -v start="$(( start_mib * 1024 * 1024 / 512 ))" '$2 == "part" && $3 == start { print $1; exit }')
if [[ -z "$models_part" || ! -b "$models_part" ]]; then
  echo "ERROR: could not discover models partition at ${start_mib}MiB." >&2
  exit 1
fi

if blkid -o value -s TYPE "$models_part" 2>/dev/null | grep -qx ext4 \
  && blkid -o value -s LABEL "$models_part" 2>/dev/null | grep -qx models; then
  echo "Preserving existing ext4 filesystem labelled 'models' on $models_part."
else
  echo "No existing ext4 filesystem labelled 'models' found at ${start_mib}MiB. Formatting $models_part..."
  wipefs -a "$models_part" || true
  mkfs.ext4 -F -L models "$models_part"
fi
sync
partprobe "$USB" || true
udevadm settle || true

cat >&2 <<EOF
Done.

USB layout:
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS "$USB")

Boot a PC from $USB. The live system will mount the writable partition at /models.
EOF
