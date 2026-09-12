{
  description = "Interorm's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent.url = "github:NousResearch/hermes-agent";

    # age-encrypted secrets, decrypted at activation with the host's SSH key.
    # See secrets/secrets.nix for who can decrypt what, and
    # modules/services/secrets/ for the host wiring.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      # Darwin deps are dead weight on a Linux-only fleet.
      inputs.darwin.follows = "";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";

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

          modules = [
            ./hosts/homeserver/default.nix

            inputs.agenix.nixosModules.default

            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = { inherit inputs; };
              home-manager.backupFileExtension = "hm-bak";
            }
          ];
        };
      };

      # `nix build .#env-ml` -- also what per-project flakes extend.
      packages.${system}.env-ml = pythonEnvs.base;

      lib.env_ML = pythonEnvs;
    };
}
