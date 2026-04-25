#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo scripts/write-usb.sh <iso-file> <usb-block-device> [confirmation]

Example:
  sudo scripts/write-usb.sh result-iso/iso/pepikronkenix-*.iso /dev/sdX pepikronkenix

This writes the ISO to the USB device and creates an ext4 partition labelled
"models" after a fixed 4 GiB ISO area if that filesystem does not already exist
there. Existing model data in that fixed area is preserved. ALL OTHER DATA ON
THE DEVICE WILL BE DESTROYED.

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
reserved_mib=${PEPIKRONKENIX_ISO_RESERVED_MIB:-4096}
reserved_bytes=$(( reserved_mib * 1024 * 1024 ))

if (( iso_bytes > reserved_bytes - 16 * 1024 * 1024 )); then
  echo "ERROR: ISO is too large for the reserved ISO area." >&2
  echo "ISO size:      $iso_bytes bytes" >&2
  echo "Reserved area: ${reserved_mib} MiB" >&2
  echo "Increase PEPIKRONKENIX_ISO_RESERVED_MIB or rebuild a smaller ISO." >&2
  exit 1
fi

if (( disk_bytes <= reserved_bytes + 512 * 1024 * 1024 )); then
  echo "ERROR: USB device must be at least about 512 MiB larger than the ${reserved_mib} MiB ISO area to hold the models partition." >&2
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
at sector $existing_models_start instead of the fixed ${reserved_mib} MiB ISO
boundary at sector $fixed_start_sector.

This older layout cannot be preserved while reserving ${reserved_mib} MiB for
future ISO updates. Back up the models, remove/recreate the USB once with this
new writer, then future writes can preserve the models filesystem.
EOF
    exit 1
  fi
fi

echo "Writing the ISO area. Existing model data after ${reserved_mib}MiB will not be touched."

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

# Keep a fixed 4 GiB (by default) area for the hybrid ISO at the start of the
# USB stick. The writable models filesystem starts after that fixed area. This
# lets future ISO updates rewrite only the beginning of the stick and recreate
# the partition table entry without touching the slow-to-copy model data.
start_mib=$reserved_mib
disk_mib=$(( disk_bytes / (1024 * 1024) ))

if (( disk_mib - start_mib < 512 )); then
  echo "ERROR: not enough free space remains for a useful models partition." >&2
  exit 1
fi

echo "Creating/restoring writable ext4 partition entry labelled 'models' from ${start_mib}MiB to end of disk..."
# Hybrid NixOS ISOs commonly expose an msdos partition table after writing.
# On msdos, parted expects a partition type such as "primary" here; on GPT,
# the same token is accepted as the partition name. mkpart only creates the
# partition table entry; it does not format or wipe an existing filesystem at
# that offset.
parted -s -a optimal "$USB" mkpart primary ext4 "${start_mib}MiB" 100%
partprobe "$USB" || true
udevadm settle || true
sleep 2

# Pick the partition that starts at the fixed model-data offset. Hybrid NixOS
# ISOs can contain small boot partitions near the start of the disk whose
# partition numbers are higher than the appended writable partition, so "last
# partition in lsblk output" is not a reliable way to find it.
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
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$USB")

Note: NixOS hybrid ISOs usually show the ISO9660 filesystem on the whole disk
($USB), plus partition entries such as a small EFI boot partition and the
appended ext4 'models' partition. A separate "live ISO" partition is not
required.

Boot a PC from $USB. The live system will mount the writable partition at /models.
EOF
