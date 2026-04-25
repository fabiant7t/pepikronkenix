{
  description = "pepikronkenix: a NixOS live USB that serves Kronk on an OpenAI-compatible API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      mkIso = processor: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./nix/live.nix
          ({ ... }: {
            pepikronkenix.processor = processor;
          })
        ];
      };

      mkAllIso = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit self; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./nix/live.nix
          ({ lib, ... }: {
            # CPU is the preselected fallback boot entry. The other entries
            # are NixOS specialisations in the same ISO image.
            pepikronkenix = {
              processor = "cpu";
              imageProfileName = "all";
            };

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
        # Default build output: one ISO with a CPU fallback boot entry plus
        # Vulkan/CUDA/ROCm boot specialisations.
        pepikronkenix = mkAllIso;
        pepikronkenix-all = mkAllIso;

        # Single-profile images remain available for smaller/specialised builds.
        pepikronkenix-cpu = mkIso "cpu";
        pepikronkenix-vulkan = mkIso "vulkan";
        pepikronkenix-cuda = mkIso "cuda";
        pepikronkenix-rocm = mkIso "rocm";
      };
    };
}
