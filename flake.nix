{
  description = "pepikronkenix: a NixOS live USB that serves Kronk on an OpenAI-compatible API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      mkImage = processor: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
          ./nix/live.nix
          ({ ... }: {
            pepikronkenix.processor = processor;
            image.format = "raw";
            virtualisation.diskSize = 6144;
          })
        ];
      };

      mkAllImage = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/disk-image.nix"
          ./nix/live.nix
          ({ lib, ... }: {
            # CPU is the preselected fallback boot entry. The other entries
            # are NixOS specialisations in the same disk image.
            pepikronkenix = {
              processor = "cpu";
              imageProfileName = "all";
            };
            image.format = "raw";
            virtualisation.diskSize = 8192;

            specialisation = {
              vulkan.configuration = { lib, ... }: {
                pepikronkenix.processor = lib.mkForce "vulkan";
              };
              cuda.configuration = { lib, ... }: {
                pepikronkenix.processor = lib.mkForce "cuda";
              };
              rocm.configuration = { lib, ... }: {
                pepikronkenix.processor = lib.mkForce "rocm";
              };
            };
          })
        ];
      };
    in {
      packages.${system} = {
        kronk = pkgs.callPackage ./nix/kronk.nix { };
        default = self.packages.${system}.kronk;
      };

      nixosConfigurations = {
        # Default build output: one disk image with a CPU fallback boot entry plus
        # Vulkan/CUDA/ROCm boot specialisations.
        pepikronkenix = mkAllImage;
        pepikronkenix-all = mkAllImage;

        # Single-profile images remain available for smaller/specialised builds.
        pepikronkenix-cpu = mkImage "cpu";
        pepikronkenix-vulkan = mkImage "vulkan";
        pepikronkenix-cuda = mkImage "cuda";
        pepikronkenix-rocm = mkImage "rocm";
      };
    };
}
