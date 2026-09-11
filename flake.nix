{
  description = "Interorm's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hermes-agent.url = "github:NousResearch/hermes-agent";

    # MCP servers, pinned to exact commits so an upstream change can't
    # silently alter what the agents run.  Re-pin deliberately with
    # `nix flake update <name>` (or by hand), then review the new revision.
    #
    # lean-lsp-mcp audited 2026-09 (no eval/exec, list-form subprocesses only,
    # path sandbox, hardcoded search URLs, TLS via certifi).  Do not enable its
    # --loogle-local flag: it clones and compiles a third-party repo.
    lean-lsp-mcp.url = "github:oOo0oOo/lean-lsp-mcp/bb176c58a4f895061561685318e92b8db446f1b5";
    mcp-nixos.url = "github:utensils/mcp-nixos/6a517811658c21f97bd7703b35546085117fc310";
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
