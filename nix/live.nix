{ config, lib, pkgs, self, ... }:

let
  cfg = config.pepikronkenix;
  hostSystem = pkgs.stdenv.hostPlatform.system;
  kronk = self.packages.${hostSystem}.kronk;
  imageProfileName = if cfg.imageProfileName == null then cfg.processor else cfg.imageProfileName;
  processorLabel = {
    cpu = "CPU";
    vulkan = "Vulkan";
    cuda = "CUDA";
    rocm = "ROCm";
  }.${cfg.processor};
  kronkEnv = {
    HOME = "/models";
    KRONK_BASE_PATH = "/models/kronk";
    KRONK_MODELS = "/models/kronk/models";
    KRONK_LIB_PATH = "/models/kronk/libraries";
    KRONK_WEB_API_HOST = "0.0.0.0:11435";
    KRONK_WEB_CORS_ALLOWED_ORIGINS = "*";
    KRONK_PROCESSOR = cfg.processor;
    KRONK_DOWNLOAD_ENABLED = "true";
    # The Kronk package wrapper prepends its Nix-store runtime libraries to this,
    # so dlopen can see both the downloaded llama.cpp files and Nix-provided
    # libstdc++/libgomp/libffi.
    LD_LIBRARY_PATH = "/models/kronk/libraries:/run/opengl-driver/lib";
    # Keep the live system predictable. Run `kronk libs --local` manually if you
    # intentionally want to upgrade the llama.cpp backend on the writable disk.
    KRONK_ALLOW_UPGRADE = "false";
  };

  envLines = lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") kronkEnv;
  envBlock = lib.concatStringsSep "\n" envLines;

  withKronkEnv = command: ''
    set -euo pipefail
    ${envBlock}
    ${command}
  '';

  kronkEnvArgs = lib.concatStringsSep " " (lib.mapAttrsToList (name: value: "${name}=${lib.escapeShellArg value}") kronkEnv);

  statusScript = pkgs.writeShellScriptBin "pepikronkenix-status" (withKronkEnv ''
    echo "pepikronkenix"
    echo
    echo "Network addresses:"
    ${pkgs.iproute2}/bin/ip -brief address show scope global || true
    echo
    echo "OpenAI-compatible endpoint:"
    for ip in $(${pkgs.iproute2}/bin/ip -4 -o address show scope global | ${pkgs.gawk}/bin/awk '{ split($4, a, "/"); print a[1] }'); do
      echo "  http://$ip:11435/v1"
    done
    echo "  http://pepikronkenix.local:11435/v1  (if mDNS works on your LAN)"
    echo
    echo "Kronk service:"
    ${pkgs.systemd}/bin/systemctl --no-pager --plain status kronk.service || true
    echo
    echo "Models visible to the API:"
    ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:11435/v1/models | ${pkgs.jq}/bin/jq . || true
    echo
    echo "Model disk:"
    if ${pkgs.util-linux}/bin/findmnt --mountpoint /models >/dev/null; then
      ${pkgs.util-linux}/bin/findmnt /models || true
    else
      echo "WARNING: /models is not mounted; model data is on the live tmpfs and will not persist."
    fi
    ${pkgs.coreutils}/bin/df -h /models || true
    echo
    echo "Block devices:"
    ${pkgs.util-linux}/bin/lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
    echo
    echo "Model mount service:"
    ${pkgs.systemd}/bin/systemctl --no-pager --plain status pepikronkenix-mount-models.service || true
  '');

  indexScript = pkgs.writeShellScriptBin "pepikronkenix-index-models" (withKronkEnv ''
    umask 0002
    mkdir -p /models/kronk/models /models/kronk/libraries
    chmod g+rwxs /models/kronk /models/kronk/models /models/kronk/libraries 2>/dev/null || true
    exec ${pkgs.coreutils}/bin/env ${kronkEnvArgs} \
      ${kronk}/bin/kronk model index --local
  '');
in
{
  options.pepikronkenix.processor = lib.mkOption {
    type = lib.types.enum [ "cpu" "vulkan" "cuda" "rocm" ];
    default = "cpu";
    description = "Kronk/llama.cpp backend to use on the live system.";
  };

  options.pepikronkenix.imageProfileName = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Profile name used in the generated disk image file name. When null, the
      selected processor name is used. Set this to a shared value such as "all"
      for images that contain multiple boot specialisations.
    '';
  };

  config = {
    image.baseName = lib.mkForce "pepikronkenix-${imageProfileName}-${config.system.nixos.label}-${hostSystem}";
    system.nixos = {
      distroName = "pepikronkenix";
      variant_id = "live";
      variantName = "pepikronkenix live USB";
    };
  networking.hostName = "pepikronkenix";

  # The CUDA boot profile needs NVIDIA's official/proprietary driver stack so
  # Kronk's CUDA llama.cpp backend can dlopen libcuda.so from
  # /run/opengl-driver/lib.
  nixpkgs.config.allowUnfree = true;
  services.xserver.videoDrivers = lib.mkIf (cfg.processor == "cuda") [ "nvidia" ];
  hardware.nvidia = lib.mkIf (cfg.processor == "cuda") {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false;
    modesetting.enable = true;
    nvidiaPersistenced = true;
  };
  # The live USB uses ordinary GPT partitions: an EFI system partition, a NixOS
  # root partition, and an appended ext4 models partition.
  boot.supportedFilesystems = [ "ext4" ];
  boot.kernelModules = [ "ext4" ] ++ lib.optionals (cfg.processor == "cuda") [
    "nvidia"
    "nvidia_uvm"
    "nvidia_modeset"
    "nvidia_drm"
  ];

  # Make the live medium discoverable and reachable on a LAN.
  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 11435 ];
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # No SSH server and no sudo: the live system should be a guest that borrows
  # compute hardware, not an administration endpoint for the host PC. Add models
  # by shutting down, mounting the USB's ext4 partition labelled "models" on a
  # different computer, and copying GGUF files there.
  services.openssh.enable = false;
  security.sudo.enable = false;

  users.groups.models = { };
  users.groups.kronk = { };
  users.users.kronk = {
    isSystemUser = true;
    group = "kronk";
    extraGroups = [ "models" "video" "render" ];
    home = "/models";
    createHome = false;
  };
  users.users.pepi = {
    isNormalUser = true;
    description = "pepikronkenix live user";
    # systemd-journal is read-only access to system logs. It is intentionally
    # much narrower than sudo/wheel, but lets the autologin user see why the
    # model partition did or did not mount on headless/live-USB boots.
    extraGroups = [ "networkmanager" "models" "video" "render" "systemd-journal" ];
    hashedPassword = "!";
  };
  services.getty.autologinUser = lib.mkForce "pepi";

  # The write-usb script creates this partition after writing the raw disk image.
  # If the system is booted without that partition, /models stays as a writable
  # directory on the live root filesystem instead.
  fileSystems."/models" = {
    device = "/dev/disk/by-label/models";
    fsType = "ext4";
    options = [ "nofail" "noauto" ];
  };
  systemd.tmpfiles.rules = [
    "d /models 2775 root models -"
    "d /models/kronk 2775 kronk models -"
    "d /models/kronk/models 2775 kronk models -"
    "d /models/kronk/libraries 2775 kronk models -"
  ];

  systemd.services.pepikronkenix-mount-models = {
    description = "Mount the writable pepikronkenix model partition if present";
    wantedBy = [ "multi-user.target" ];
    before = [ "pepikronkenix-models.service" ];
    after = [ "local-fs.target" "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      log=/run/pepikronkenix-mount-models.log
      ${pkgs.coreutils}/bin/touch "$log"
      ${pkgs.coreutils}/bin/chmod 0644 "$log"
      exec > >(${pkgs.coreutils}/bin/tee -a "$log") 2>&1
      echo "=== pepikronkenix model mount check: $(${pkgs.coreutils}/bin/date -Is) ==="

      ${pkgs.coreutils}/bin/install -d -m 2775 -o root -g models /models

      if ${pkgs.util-linux}/bin/findmnt --mountpoint /models >/dev/null; then
        echo "/models is already mounted"
        exit 0
      fi

      ${pkgs.systemd}/bin/udevadm trigger --subsystem-match=block || true
      ${pkgs.systemd}/bin/udevadm settle --timeout=60 || true
      ${pkgs.kmod}/bin/modprobe ext4 || true

      models_device=""
      for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
        if [ -e /dev/disk/by-label/models ]; then
          models_device=/dev/disk/by-label/models
          break
        fi

        # Fallbacks for cases where the block device is visible but the by-label
        # symlink has not been created yet. blkid probes devices directly;
        # lsblk is useful when udev's database already knows the filesystem.
        models_device="$(${pkgs.util-linux}/bin/blkid -t TYPE=ext4 -t LABEL=models -o device 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)"
        if [ -n "$models_device" ]; then
          break
        fi

        models_device="$(${pkgs.util-linux}/bin/lsblk -nrpo NAME,FSTYPE,LABEL \
          | ${pkgs.gawk}/bin/awk '$2 == "ext4" && $3 == "models" { print $1; exit }')"
        if [ -n "$models_device" ]; then
          break
        fi

        ${pkgs.coreutils}/bin/sleep 1
      done

      if [ -z "$models_device" ]; then
        echo "WARNING: no ext4 partition labelled 'models' found; using non-persistent live tmpfs at /models" >&2
        ${pkgs.util-linux}/bin/lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS || true
        ${pkgs.util-linux}/bin/blkid || true
        exit 0
      fi

      models_real_device="$(${pkgs.coreutils}/bin/readlink -f "$models_device" || printf '%s\n' "$models_device")"
      echo "Found model partition: $models_device ($models_real_device)"
      ${pkgs.util-linux}/bin/lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$models_real_device" || true

      # If the stick was unplugged without a clean unmount while models were
      # copied, ext4 may require journal replay/fsck before it will mount.
      ${pkgs.e2fsprogs}/bin/e2fsck -p "$models_real_device" || true

      echo "Mounting $models_real_device at /models"
      ${pkgs.util-linux}/bin/mount -t ext4 -o rw "$models_real_device" /models || {
        echo "ERROR: failed to mount $models_real_device; using non-persistent live root storage at /models" >&2
        ${pkgs.util-linux}/bin/lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS || true
        ${pkgs.util-linux}/bin/blkid || true
        ${pkgs.util-linux}/bin/dmesg | ${pkgs.coreutils}/bin/tail -n 80 || true
        echo "The same diagnostics are readable at $log" >&2
        exit 1
      }

      echo "Mounted $models_real_device at /models successfully"
      ${pkgs.util-linux}/bin/findmnt /models || true
    '';
  };

  systemd.services.pepikronkenix-models = {
    description = "Prepare the writable pepikronkenix model store";
    wantedBy = [ "multi-user.target" ];
    before = [ "kronk.service" "pepikronkenix-kronk-libs.service" ];
    after = [ "local-fs.target" "pepikronkenix-mount-models.service" ];
    wants = [ "pepikronkenix-mount-models.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 2775 -o kronk -g models /models/kronk /models/kronk/models /models/kronk/libraries
      chown root:models /models || true
      chmod 2775 /models || true
      chown kronk:models /models/kronk /models/kronk/models /models/kronk/libraries || true
      chmod 2775 /models/kronk /models/kronk/models /models/kronk/libraries || true
    '';
  };

  systemd.services.pepikronkenix-kronk-libs = {
    description = "Install Kronk llama.cpp runtime libraries onto the writable model disk if missing";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "pepikronkenix-models.service" ];
    wants = [ "network-online.target" "pepikronkenix-models.service" ];
    before = [ "pepikronkenix-model-index.service" "kronk.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kronk";
      Group = "models";
      SupplementaryGroups = [ "video" "render" ];
      WorkingDirectory = "/models/kronk";
      TimeoutStartSec = "10min";
      NoNewPrivileges = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/models" ];
      PrivateTmp = true;
    };
    environment = kronkEnv;
    script = ''
      if [ -e /models/kronk/libraries/version.json ]; then
        echo "Kronk llama.cpp libraries already installed in /models/kronk/libraries"
        exit 0
      fi

      echo "Installing Kronk llama.cpp libraries for processor=${cfg.processor}. This needs internet once."
      ${kronk}/bin/kronk libs --local --no-upgrade || {
        echo "Library installation failed. Kronk may still start, but inference will not work until libraries are installed." >&2
        exit 0
      }
    '';
  };

  systemd.services.pepikronkenix-model-index = {
    description = "Index Kronk models from the writable model disk";
    wantedBy = [ "multi-user.target" ];
    after = [ "pepikronkenix-models.service" "pepikronkenix-kronk-libs.service" ];
    wants = [ "pepikronkenix-models.service" "pepikronkenix-kronk-libs.service" ];
    before = [ "kronk.service" ];
    environment = kronkEnv;
    serviceConfig = {
      Type = "oneshot";
      User = "kronk";
      Group = "models";
      WorkingDirectory = "/models/kronk";
      TimeoutStartSec = "5min";
      NoNewPrivileges = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/models" ];
      PrivateTmp = true;
    };
    script = ''
      ${kronk}/bin/kronk model index --local || {
        echo "Model indexing failed. Check permissions and paths under /models/kronk/models." >&2
        exit 0
      }
    '';
  };

  systemd.services.kronk = {
    description = "Kronk OpenAI-compatible local inference server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "pepikronkenix-models.service" "pepikronkenix-kronk-libs.service" "pepikronkenix-model-index.service" ];
    wants = [ "network-online.target" "pepikronkenix-models.service" "pepikronkenix-kronk-libs.service" "pepikronkenix-model-index.service" ];
    environment = kronkEnv;
    path = [ pkgs.bash pkgs.coreutils pkgs.curl pkgs.gawk pkgs.git pkgs.gnutar pkgs.gzip pkgs.xz pkgs.zstd ];
    serviceConfig = {
      User = "kronk";
      Group = "models";
      SupplementaryGroups = [ "video" "render" ];
      WorkingDirectory = "/models/kronk";
      ExecStart = "${kronk}/bin/kronk server start --api-host=0.0.0.0:11435 --processor=${cfg.processor}";
      NoNewPrivileges = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/models" ];
      PrivateTmp = true;
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "2min";
      LimitNOFILE = 1048576;
    };
  };

  environment.systemPackages = with pkgs; [
    kronk
    statusScript
    indexScript
    bashInteractive
    curl
    wget
    jq
    git
    vim
    nano
    htop
    tmux
    pciutils
    usbutils
    iproute2
    dnsutils
    lm_sensors
    lshw
    vulkan-tools
    clinfo
  ];

  hardware.graphics.enable = true;

  environment.etc."pepikronkenix/README.txt".text = ''
    pepikronkenix live system

    Kronk listens on: http://<this-machine-ip>:11435/v1
    Local status:     pepikronkenix-status
    Index models:     pepikronkenix-index-models (also automatic at boot)
    SSH/sudo:         disabled; copy models by mounting the USB model partition elsewhere

    Login user:       pepi (console autologin, password disabled)

    Model partition:  /models
    Kronk data:       /models/kronk
    Model files:      /models/kronk/models/<org>/<family>/*.gguf
  '';

    system.stateVersion = "25.11";
  };
}
