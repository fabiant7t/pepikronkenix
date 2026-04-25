# pepikronkenix

**pepikronkenix** builds a bootable x86_64 NixOS live USB that runs
[Kronk](https://github.com/ardanlabs/kronk) and exposes it as an
OpenAI-compatible HTTP API on:

```text
http://<live-machine-ip>:11435/v1
```

The intended workflow is:

1. Build a NixOS live ISO.
2. Write it to a USB stick.
3. Use the remaining USB space as a writable `models` partition.
4. Boot any suitable PC from the stick.
5. Upload or download GGUF models to `/models/kronk/models`.
6. Point any OpenAI-compatible client on another computer at
   `http://<ip>:11435/v1`.

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
- Hostname `pepikronkenix` and mDNS/Avahi publishing.
- SSH/SFTP enabled for uploading models.
- User `pepi` with password `kronkenix`.
- Writable ext4 partition mounted at `/models` when the USB was created with the
  provided writer script.
- Helper commands:
  - `pepikronkenix-status`
  - `pepikronkenix-index-models`
  - `pepikronkenix-pull-model <catalog-id-or-hf-ref>`

> Security note: this is a LAN appliance-style live image. Kronk authentication
> is disabled by default, SSH password login is enabled, and the default password
> is public. Use it only on trusted networks or harden the NixOS module before
> deployment.

## Repository layout

```text
flake.nix              Nix flake outputs for Kronk and live ISO profiles
nix/kronk.nix          Nix package for Kronk
nix/live.nix           NixOS live USB configuration
Makefile               Build and USB-writing convenience targets
scripts/write-usb.sh   Writes ISO and creates the writable models partition
```

## Prerequisites

On the build machine:

- Linux with Nix installed.
- Nix flakes enabled, or use the Makefile which passes the needed experimental
  feature flags.
- Enough disk space for a NixOS ISO build.
- For writing the USB stick: `sudo`, `dd`, `parted`, `wipefs`, `mkfs.ext4`,
  `lsblk`, `udevadm`.
- Optional but recommended for a nicer USB write progress bar: `pv`.

The target machine should be an x86_64 PC with enough RAM/VRAM for the models
that you want to serve. The default ISO is CPU-only and works on the widest range
of hardware. GPU profiles are provided as starting points.

## Build the ISO

Default CPU image:

```bash
make iso
```

Equivalent explicit form:

```bash
make build-cpu
```

Other profiles:

```bash
make build-vulkan
make build-cuda
make build-rocm
```

or:

```bash
make iso PROFILE=vulkan
```

The resulting ISO is printed by `make` and is usually under:

```text
result/iso/pepikronkenix-<profile>-<nixos-version>-x86_64-linux.iso
```

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

Write the latest built ISO and create the writable `models` partition:

```bash
sudo make write-usb USB=/dev/sdX CONFIRM=pepikronkenix
```

Or pass a specific ISO:

```bash
sudo make write-usb \
  ISO=result/iso/pepikronkenix-cpu-...-x86_64-linux.iso \
  USB=/dev/sdX \
  CONFIRM=pepikronkenix
```

The writer script does three things:

1. wipes old filesystem signatures from the device;
2. writes the hybrid ISO with `pv | dd` when `pv` is available, otherwise with
   `dd status=progress`;
3. creates an ext4 partition labelled `models` in the remaining free space.

At boot, NixOS mounts that partition at `/models`.

## Boot and find the API address

Boot a PC from the USB stick. The live system logs in automatically as `pepi`.

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
/models/kronk/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
/models/kronk/models/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf
```

After adding model files manually, rebuild Kronk's model index:

```bash
pepikronkenix-index-models
sudo systemctl restart kronk
```

Then verify:

```bash
curl http://127.0.0.1:11435/v1/models | jq .
```

## Upload models over the network

The live image enables SSH/SFTP. From another computer:

```bash
ssh pepi@<live-machine-ip>
# password: kronkenix
```

Create a destination directory and upload a GGUF file:

```bash
ssh pepi@<live-machine-ip> \
  'mkdir -p /models/kronk/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF'

rsync -av --progress ./Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf \
  pepi@<live-machine-ip>:/models/kronk/models/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/
```

Then index on the live machine:

```bash
pepikronkenix-index-models
sudo systemctl restart kronk
```

You can also run the index command remotely:

```bash
ssh pepi@<live-machine-ip> 'pepikronkenix-index-models && sudo systemctl restart kronk'
```

## Download models from the live machine

If the booted live PC has internet access, use the helper:

```bash
pepikronkenix-pull-model Qwen3-0.6B-Q8_0
```

For Hugging Face shorthand supported by Kronk:

```bash
pepikronkenix-pull-model unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M
```

For gated Hugging Face models, set a token in the shell before pulling:

```bash
export KRONK_HF_TOKEN=hf_...
pepikronkenix-pull-model owner/repo:Q4_K_M
```

The helper first tries `kronk catalog pull ... --local`; if that fails, it tries
`kronk model pull ... --local`, then rebuilds the model index.

## Kronk service management

Show status:

```bash
systemctl status kronk --no-pager
```

Follow logs:

```bash
journalctl -u kronk -f
```

Restart after adding models:

```bash
sudo systemctl restart kronk
```

Stop/start manually:

```bash
sudo systemctl stop kronk
sudo systemctl start kronk
```

The service runs as the system user `kronk` and uses these important variables:

```text
KRONK_BASE_PATH=/models/kronk
KRONK_MODELS=/models/kronk/models
KRONK_LIB_PATH=/models/kronk/libraries
KRONK_WEB_API_HOST=0.0.0.0:11435
KRONK_PROCESSOR=<cpu|vulkan|cuda|rocm>
```

At first boot, the live system tries to install Kronk's llama.cpp runtime
libraries into `/models/kronk/libraries`. This requires internet access once. If
that step fails, install them later:

```bash
sudo -u kronk -g models env \
  HOME=/models \
  KRONK_BASE_PATH=/models/kronk \
  KRONK_LIB_PATH=/models/kronk/libraries \
  KRONK_PROCESSOR=cpu \
  kronk libs --local --no-upgrade

sudo systemctl restart kronk
```

Use `KRONK_PROCESSOR=vulkan`, `cuda`, or `rocm` if you built and booted a GPU
profile and the target machine has the appropriate drivers/runtime support.

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
`scripts/write-usb.sh` creates it automatically. If you wrote the ISO with a
different tool, create an ext4 partition labelled `models` in the remaining USB
space.

### Kronk starts but `/v1/models` is empty

Index the models and restart:

```bash
pepikronkenix-index-models
sudo systemctl restart kronk
curl http://127.0.0.1:11435/v1/models | jq .
```

Verify that GGUF files are below the expected two-level directory structure:

```text
/models/kronk/models/<org>/<family>/*.gguf
```

### Library errors

Check whether the runtime libraries exist:

```bash
ls -la /models/kronk/libraries
cat /models/kronk/libraries/version.json
```

If missing, install them with internet access:

```bash
sudo systemctl restart pepikronkenix-kronk-libs.service
journalctl -u pepikronkenix-kronk-libs.service --no-pager
sudo systemctl restart kronk
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
