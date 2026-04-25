{ config, lib, pkgs, self, ... }:

let
  cfg = config.pepikronkenix;
  hostSystem = pkgs.stdenv.hostPlatform.system;
  kronk = self.packages.${hostSystem}.kronk;
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
    LD_LIBRARY_PATH = "/models/kronk/libraries";
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

  config = {
    image.baseName = lib.mkForce "pepikronkenix-${cfg.processor}-${config.system.nixos.label}-${hostSystem}";
  networking.hostName = "pepikronkenix";

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
    extraGroups = [ "networkmanager" "models" "video" "render" ];
    hashedPassword = "!";
  };
  services.getty.autologinUser = lib.mkForce "pepi";

  # The write-usb script creates this partition after writing the ISO. If the
  # live system is booted as a plain ISO without that partition, /models stays as
  # a writable tmpfs directory from the live system instead.
  fileSystems."/models" = {
    device = "/dev/disk/by-label/models";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };
  systemd.tmpfiles.rules = [
    "d /models 2775 root models -"
    "d /models/kronk 2775 kronk models -"
    "d /models/kronk/models 2775 kronk models -"
    "d /models/kronk/libraries 2775 kronk models -"
  ];

  systemd.services.pepikronkenix-models = {
    description = "Prepare the writable pepikronkenix model store";
    wantedBy = [ "multi-user.target" ];
    before = [ "kronk.service" "pepikronkenix-kronk-libs.service" ];
    after = [ "local-fs.target" "models.mount" ];
    wants = [ "models.mount" ];
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
