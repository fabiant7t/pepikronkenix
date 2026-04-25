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
    in {
      packages.${system} = {
        kronk = pkgs.callPackage ./nix/kronk.nix { };
        default = self.packages.${system}.kronk;
      };

      nixosConfigurations = {
        # Conservative default: works on the widest set of x86_64 PCs.
        pepikronkenix = mkIso "cpu";
        pepikronkenix-cpu = mkIso "cpu";

        # Experimental profiles. They include the same live system but ask Kronk
        # to download/use the matching llama.cpp backend at runtime.
        pepikronkenix-vulkan = mkIso "vulkan";
        pepikronkenix-cuda = mkIso "cuda";
        pepikronkenix-rocm = mkIso "rocm";
      };
    };
}
