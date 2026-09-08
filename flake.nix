{
  description = "Interorm's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";

      # A nixpkgs instance for the flake's *own* outputs (packages, lib,
      # devShells).  The nixosConfigurations below do NOT use this one -- each
      # of them builds its own `pkgs` from the `nixpkgs.*` options set inside
      # its modules.
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      pythonEnvs = import ./modules/python-envs/env_ML.nix { inherit pkgs; };
    in
    {
      nixosConfigurations = {
        Karls-PC = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };

          modules = [
            ./hosts/PC/default.nix

            # Two separate list elements: the home-manager NixOS module, and an
            # inline module configuring it.
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              # Without this, the first switch aborts if ~/.config/git/config
              # already exists.  With it, the old file is moved aside.
              home-manager.backupFileExtension = "hm-bak";
              home-manager.users.karl = import ./home/karl;
            }
          ];
        };

        homeserver = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };

          modules = [ ./hosts/homeserver/default.nix ];
        };
      };

      # `nix build .#env-ml` -- also what per-project flakes extend.
      packages.${system}.env-ml = pythonEnvs.base;

      lib.env_ML = pythonEnvs;
    };
}
