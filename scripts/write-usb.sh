#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo scripts/write-usb.sh <iso-file> <usb-block-device> [confirmation]

Example:
  sudo scripts/write-usb.sh result-iso/iso/pepikronkenix-*.iso /dev/sdX pepikronkenix

This writes the ISO to the USB device and creates an ext4 partition labelled
"models" in the remaining free space. ALL DATA ON THE DEVICE WILL BE DESTROYED.

Safety confirmation must be the literal word: pepikronkenix
EOF
}

ISO=${1:-}
USB=${2:-}
CONFIRMATION=${3:-${CONFIRM:-}}

if [[ -z "$ISO" || -z "$USB" ]]; then
  usage
  exit 2
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: this script must run as root because it writes block devices." >&2
  exit 1
fi

if [[ "$CONFIRMATION" != "pepikronkenix" ]]; then
  usage
  echo >&2
  echo "ERROR: missing safety confirmation. Pass CONFIRM=pepikronkenix via make or the third argument." >&2
  exit 1
fi

if [[ ! -f "$ISO" ]]; then
  echo "ERROR: ISO file not found: $ISO" >&2
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

$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$USB")

ISO: $ISO
USB: $USB
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

iso_bytes=$(stat -c %s "$ISO")
disk_bytes=$(blockdev --getsize64 "$USB")

if (( disk_bytes <= iso_bytes + 1024 * 1024 * 1024 )); then
  echo "ERROR: USB device must be at least about 1 GiB larger than the ISO to hold the models partition." >&2
  exit 1
fi

echo "Wiping old signatures..."
wipefs -a "$USB" || true

if command -v pv >/dev/null 2>&1; then
  echo "Writing ISO with progress bar..."
  pv -s "$iso_bytes" "$ISO" | dd of="$USB" bs=4M status=none conv=fsync
else
  echo "Writing ISO. Install 'pv' for a nicer progress bar."
  dd if="$ISO" of="$USB" bs=4M status=progress conv=fsync
fi
sync

# Give the kernel a chance to notice the ISO partition table.
partprobe "$USB" || true
udevadm settle || true
sleep 2

# Start the writable partition after the ISO image, aligned to MiB with a small
# guard gap. Hybrid ISO partition layouts differ; placing the extra partition
# after the image is the most robust strategy.
start_mib=$(( (iso_bytes + 1024 * 1024 - 1) / (1024 * 1024) + 16 ))
disk_mib=$(( disk_bytes / (1024 * 1024) ))

if (( disk_mib - start_mib < 512 )); then
  echo "ERROR: not enough free space remains for a useful models partition." >&2
  exit 1
fi

echo "Creating writable ext4 partition labelled 'models' from ${start_mib}MiB to end of disk..."
# Hybrid NixOS ISOs commonly expose an msdos partition table after writing.
# On msdos, parted expects a partition type such as "primary" here; on GPT,
# the same token is accepted as the partition name. The filesystem label is set
# to "models" by mkfs.ext4 below, which is what the live system mounts.
parted -s -a optimal "$USB" mkpart primary ext4 "${start_mib}MiB" 100%
partprobe "$USB" || true
udevadm settle || true
sleep 2

models_part=$(lsblk -nrpo NAME,TYPE "$USB" | awk '$2 == "part" { p=$1 } END { print p }')
if [[ -z "$models_part" || ! -b "$models_part" ]]; then
  echo "ERROR: could not discover newly-created models partition." >&2
  exit 1
fi

echo "Formatting $models_part as ext4 with label 'models'..."
mkfs.ext4 -F -L models "$models_part"
sync

cat >&2 <<EOF
Done.

USB layout:
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$USB")

Boot a PC from $USB. The live system will mount the writable partition at /models.
EOF
