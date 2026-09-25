{
  description = "Interorm's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned to a release tag, not `main`: an unpinned input silently drifts
    # to whatever landed upstream on the next `nix flake update`, which for an
    # agent holding live sessions in state.db is not a change you want to make
    # by accident.  v2026.9.11 = 0.21.2, the state.db reliability patch.
    hermes-agent.url = "github:NousResearch/hermes-agent/v2026.9.11";

    # age-encrypted secrets, decrypted at activation with the host's SSH key.
    # See secrets/secrets.nix for who can decrypt what, and
    # modules/services/secrets/ for the host wiring.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      # Darwin deps are dead weight on a Linux-only fleet.
      inputs.darwin.follows = "";
    };

    # ComfyUI source, tracked as an input instead of a version+hash pinned
    # inside the derivation (see overlays/comfyui.nix).  `flake = false`
    # because upstream is a plain Python repo, not a flake.
    #
    # Pointed at the newest upstream *release* tag.  To move to whatever is
    # newest at that moment:
    #
    #     nix flake update comfyui-src          # -> newest release tag
    #
    # flake.lock records the exact commit, so every rebuild stays
    # reproducible and the jump is visible in the lock diff during review.
    #
    # NOTE: `ref` is the release tag, not `master`.  Upstream's master is
    # their development branch and regularly carries unreleased work; the
    # tag is what they call stable.  Change `ref` to the newer tag (or to
    # `master` if you want the true bleeding edge) and re-run the update.
    comfyui-src = {
      url = "github:Comfy-Org/ComfyUI/v0.37.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";

      # The overlay needs the ComfyUI source; everything else about it is
      # derived (version is read out of the tree, deps come from nixpkgs).
      comfyuiOverlay = import ./overlays/comfyui.nix {
        src = inputs.comfyui-src;
      };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ comfyuiOverlay ];
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

            # The overlay has to reach the system's pkgs, not just the
            # flake's `packages` output -- `nixosSystem` builds its own
            # pkgs, so without this `services.comfyui.package` would
            # resolve to nixpkgs' (older) comfyui.
            { nixpkgs.overlays = [ comfyuiOverlay ]; }

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
      # `nix build .#comfyui` -- overlaid ComfyUI (overlays/comfyui.nix).
      # One attrset: `packages.${system}` may only be defined once.
      packages.${system} = {
        env-ml               = pythonEnvs.base;
        comfyui              = pkgs.comfyui;
        comfyui-with-manager = pkgs.comfyui-with-manager;
      };

      lib.env_ML = pythonEnvs;
    };
}
