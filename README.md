# pepikronkenix

**pepikronkenix** builds a bootable x86_64 NixOS live USB that runs
[Kronk](https://github.com/ardanlabs/kronk) and exposes it as an
OpenAI-compatible HTTP API on:

```text
http://<live-machine-ip>:11435/v1
```

The name is brilliant because Kronk's real name is Kronker Pepikrankenitz, and
**pepikronkenix** neatly includes `pi` (the world's very best coding agent),
`kronk`, and `nix`.

The intended workflow is:

1. Build a NixOS live USB disk image.
2. Write it to a USB stick; the writer uses the remaining USB space as a
   writable `models` partition.
3. On a trusted/admin computer, mount the USB's `models` partition and copy GGUF
   models to `kronk/models` on that partition.
4. Boot any suitable target PC from the stick; models are indexed automatically.
5. Point any OpenAI-compatible client on the LAN at `http://<ip>:11435/v1`.

## Related projects

This project is a small integration/build wrapper around these upstream projects
and technologies:

- [Gemma 4](https://deepmind.google/models/gemma/gemma-4/) — an example family
  of open models that can be served through the live API when available in a
  Kronk-supported format.
- [Kronk](https://github.com/ardanlabs/kronk) — the local LLM inference server
  exposed by this live USB.
- [Yzma](https://github.com/hybridgroup/yzma) — related Go/native inference
  tooling from Hybrid Group.
- [purego](https://github.com/ebitengine/purego) — Go dynamic library loading
  used in the broader native-library ecosystem.
- [ffi](https://github.com/JupiterRider/ffi) — Go FFI support used by Kronk's
  native runtime stack.
- [NixOS](https://nixos.org/) — the reproducible Linux distribution used to
  build the bootable live USB.

## What the live system provides

- NixOS minimal live system.
- `kronk` built from `github.com/ardanlabs/kronk/cmd/kronk`.
- Kronk server bound to `0.0.0.0:11435`.
- Firewall port `11435/tcp` opened.
- Boot menu, hostname, and mDNS/Avahi publishing branded as
  `pepikronkenix`.
- No SSH server, no password login, and no sudo for the live user.
- Console autologin as unprivileged user `pepi`.
- Writable ext4 partition mounted at `/models` when the USB was created with the
  provided writer script.
- Automatic model indexing at boot.
- Helper commands:
  - `pepikronkenix-status`
  - `pepikronkenix-index-models`

> Security note: this is a guest/appliance-style live disk image. Kronk
> authentication is disabled and the API is exposed on the LAN, but the image
> deliberately does not run SSH and does not grant sudo to the console user. Add
> models by mounting the USB model partition from another computer, not by
> logging into the target PC over the network.

## Repository layout

```text
flake.nix              Nix flake outputs for Kronk and live disk-image profiles
nix/kronk.nix          Nix package for Kronk
nix/live.nix           NixOS live USB configuration
Makefile               Build and USB-writing convenience targets
scripts/write-usb.sh   Writes disk image and creates the writable models partition
```

## Prerequisites

On the build machine:

- Linux with Nix installed.
- Nix flakes enabled, or use the Makefile which passes the needed experimental
  feature flags.
- Enough disk space for a NixOS disk-image build.
- For writing the USB stick: `sudo`, `dd`, `parted`, `sgdisk` from gptfdisk,
  `wipefs`, `mkfs.ext4`, `lsblk`, `udevadm`.
- Optional but recommended for a nicer USB write progress bar: `pv`.

The target machine should be an x86_64 PC with enough RAM/VRAM for the models
that you want to serve. The default build profile is the all-in-one disk image, which
contains CPU, Vulkan, CUDA, and ROCm boot entries. Within that boot menu, CPU is
the preselected fallback entry because it works on the widest range of hardware.

## Build the disk image

Default all-in-one image:

```bash
make image
```

Equivalent explicit form:

```bash
make build-all
```

This produces a single raw disk image with boot menu entries for:

- `CPU` — preselected fallback boot entry, widest compatibility;
- `Vulkan`;
- `CUDA` — includes NVIDIA's official/proprietary driver stack and enables
  unfree packages in the NixOS configuration so `libcuda.so` is available;
- `ROCm`.

Single-profile images are still available when you want a smaller/specialised
build:

```bash
make build-cpu
make build-vulkan
make build-cuda
make build-rocm
```

or:

```bash
make image PROFILE=vulkan
```

The resulting disk image is printed by `make` and is usually under:

```text
result/pepikronkenix-<profile>-efi-raw-<nixos-version>-x86_64-linux.img
```

For the default all-in-one image, `<profile>` is `all`.

You can also build only the Kronk package:

```bash
make kronk
./result/bin/kronk --help
```

## Write the USB stick

> Warning: this destroys all data on the selected device.

Find the USB device:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
```

Use the whole disk device, for example `/dev/sdX`, `/dev/nvme1n1`, or
`/dev/mmcblk0`, not a partition such as `/dev/sdX1`.

Write the latest built disk image and create the writable `models` partition:

```bash
sudo make write-usb USB=/dev/sdX CONFIRM=pepikronkenix
```

Or pass a specific disk image:

```bash
sudo make write-usb \
  IMAGE=result/pepikronkenix-all-efi-raw-...-x86_64-linux.img \
  USB=/dev/sdX \
  CONFIRM=pepikronkenix
```

The writer script keeps the first 8 GiB of the USB stick reserved for the
raw disk image. The writable `models` partition starts after that fixed area.
This makes future image updates much faster: if an ext4 filesystem labelled
`models` already exists at the 8 GiB boundary, the script rewrites the image
area, relocates the GPT backup header to the end of the USB device, and restores
the partition table entry without reformatting or recopying model data.

If the script finds an older `models` partition that starts before the 8 GiB
boundary, it aborts instead of risking model data loss. Back up that partition
and recreate the stick once with the new layout; subsequent image updates can
then preserve the model data in place.

The writer script does two things:

1. writes the raw disk image into the reserved 8 GiB area with `pv | dd` when `pv`
   is available, otherwise with `dd status=progress`;
2. creates or restores an ext4 partition entry labelled `models` after the fixed
   8 GiB image area, formatting it only when no existing `models` filesystem is
   found there.

At boot, NixOS mounts that partition at `/models`.

pepikronkenix USB sticks use a normal GPT partition table with an EFI system
partition, a NixOS root partition, and the appended `models` partition.

## Boot and find the API address

Boot a PC from the USB stick. In the default all-in-one disk image, choose the best
processor backend from the boot menu; if unsure, pick `CPU` or let the timeout
select the CPU fallback automatically. Choose `CUDA` only on machines with
supported NVIDIA GPUs; that entry loads NVIDIA's official driver. The live
system logs in automatically as `pepi`.

Run:

```bash
pepikronkenix-status
```

Look for addresses like:

```text
http://192.168.1.42:11435/v1
```

If mDNS works on your network, this may also work from another machine:

```text
http://pepikronkenix.local:11435/v1
```

Check the API locally on the live machine:

```bash
curl http://127.0.0.1:11435/v1/models | jq .
```

From another machine on the same LAN:

```bash
curl http://<live-machine-ip>:11435/v1/models | jq .
```

## Model storage

The persistent model disk is:

```text
/models
```

Kronk's base path is:

```text
/models/kronk
```

Kronk expects model files below:

```text
/models/kronk/models/<org>/<model-family>/*.gguf
```

Examples:

```text
/models/kronk/models/unsloth/gemma-4-E4B-it/gemma-4-E4B-it-Q4_K_M.gguf
/models/kronk/models/unsloth/gemma-4-26B-A4B-it-UD/gemma-4-26B-A4B-it-UD-Q5_K_M.gguf
```

When the live USB boots, it indexes this directory automatically before starting
Kronk. If you change the model partition, reboot the target PC so the service
starts from a fresh index.

Then verify:

```bash
curl http://127.0.0.1:11435/v1/models | jq .
```

## Add models by mounting the USB partition elsewhere

The live image intentionally does **not** enable SSH/SFTP. The target PC should
act as a guest that only borrows CPU/GPU hardware; it should not expose a shell
that can administer the machine.

To add models:

1. Shut down the live system.
2. Move the USB stick to another Linux computer.
3. Mount the ext4 partition labelled `models`.
4. Copy GGUF files under `kronk/models/<org>/<family>/` on that mounted
   partition.
5. Unmount cleanly and boot the target PC from the USB stick again.

Example on the computer where you copy models:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
sudo mkdir -p /mnt/pepikronkenix-models
sudo mount /dev/disk/by-label/models /mnt/pepikronkenix-models

sudo mkdir -p \
  /mnt/pepikronkenix-models/kronk/models/unsloth/gemma-4-E4B-it
sudo cp ./gemma-4-E4B-it-Q4_K_M.gguf \
  /mnt/pepikronkenix-models/kronk/models/unsloth/gemma-4-E4B-it/

# Make sure the guest service can read files regardless of UID/GID differences.
sudo find /mnt/pepikronkenix-models/kronk/models -type d -exec chmod 755 {} +
sudo find /mnt/pepikronkenix-models/kronk/models -type f -exec chmod 644 {} +

sync
sudo umount /mnt/pepikronkenix-models
```

On next boot, `pepikronkenix-model-index.service` indexes the files before
`kronk.service` starts.

## Kronk service management

Show status:

```bash
systemctl status kronk --no-pager
```

Follow logs:

```bash
journalctl -u kronk -f
```

After adding models by mounting the USB partition elsewhere, reboot the live
system. Model indexing runs automatically before Kronk starts.

The service runs as the system user `kronk` and uses these important variables:

```text
KRONK_BASE_PATH=/models/kronk
KRONK_MODELS=/models/kronk/models
KRONK_LIB_PATH=/models/.kronk/libraries
KRONK_WEB_API_HOST=0.0.0.0:11435
KRONK_PROCESSOR=<cpu|vulkan|cuda|rocm>
```

At first boot, the live system tries to install Kronk's llama.cpp runtime
libraries into `/models/.kronk/libraries`. This requires internet access once. If
that step fails, boot again later with internet access; the library installer
service is retried at boot while the libraries are missing.

The library installer is profile-aware. It records the selected backend plus a
small hardware signature in
`/models/.kronk/libraries/.pepikronkenix-library-profile`. The signature includes
the selected processor mode, machine architecture, CPU feature flags, and visible
display/GPU PCI devices. If a later boot selects a different backend or runs on
different hardware, pepikronkenix removes the old runtime libraries before
installing the newly selected backend. This prevents CPU/Vulkan/CUDA/ROCm or
hardware-specific fragments from a previous boot from deciding the runtime
architecture of the current boot.

The selected boot entry sets `KRONK_PROCESSOR` automatically. Use a GPU entry
only when the target machine has the appropriate hardware and driver/runtime
support.

## Test text generation

Replace `<model-id>` with an ID returned by `/v1/models`:

```bash
curl http://<live-machine-ip>:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<model-id>",
    "messages": [
      {"role": "user", "content": "Say hello from pepikronkenix."}
    ],
    "stream": false
  }' | jq .
```

Streaming:

```bash
curl -N http://<live-machine-ip>:11435/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<model-id>",
    "messages": [{"role": "user", "content": "Write a short haiku."}],
    "stream": true
  }'
```

## Optional: configure Mario Zechner's pi coding harness on another computer

The live USB is just an OpenAI-compatible server. On the client computer running
pi, add a provider similar to this in `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "pepikronkenix": {
      "baseUrl": "http://<live-machine-ip>:11435/v1",
      "api": "openai-completions",
      "apiKey": "not-used",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "<model-id-from-/v1/models>",
          "name": "pepikronkenix local model",
          "contextWindow": 32768,
          "maxTokens": 8192
        }
      ]
    }
  }
}
```

Then select that model/provider in pi. The model ID must match what Kronk reports
from:

```bash
curl http://<live-machine-ip>:11435/v1/models | jq .
```

## Troubleshooting

### No `/models` persistence

Check the mount:

```bash
findmnt /models
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
```

The writable partition must be labelled `models`. The provided
`scripts/write-usb.sh` creates it automatically. If you wrote the image with a
different tool, create an ext4 partition labelled `models` in the remaining USB
space.

### Kronk starts but `/v1/models` is empty

Verify the automatic index service and API:

```bash
systemctl status pepikronkenix-model-index --no-pager
curl http://127.0.0.1:11435/v1/models | jq .
```

If you changed files while the live system was running, reboot.

Verify that GGUF files are below the expected two-level directory structure:

```text
/models/kronk/models/<org>/<family>/*.gguf
```

### Library errors

Check whether the runtime libraries exist:

```bash
ls -la /models/.kronk/libraries
cat /models/.kronk/libraries/version.json
cat /models/.kronk/libraries/.pepikronkenix-library-profile
```

If missing, boot the live system with internet access and inspect the installer
logs:

```bash
journalctl -u pepikronkenix-kronk-libs.service --no-pager
```

### Cannot reach the API from another machine

On the live machine:

```bash
ip -brief address show scope global
systemctl status kronk --no-pager
ss -ltnp | grep 11435
```

From the client machine:

```bash
ping <live-machine-ip>
curl -v http://<live-machine-ip>:11435/v1/models
```

Make sure both machines are on the same network and that the network does not
block peer-to-peer client traffic.

## Development notes

Evaluate flake outputs:

```bash
make check
```

Clean local result symlinks:

```bash
make clean
```

The `nix/kronk.nix` package pins Kronk and its Go vendor hash for reproducible
builds. Update the version, source hash, and vendor hash together when updating
Kronk.
