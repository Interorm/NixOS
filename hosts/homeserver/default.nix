{
    pkgs, config, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix
        ./secrets.nix

        ../../modules/services/backup.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix
        ../../modules/development/lean-math.nix

        ../../modules/services/minecraft/crafty.nix

        #../../modules/services/openwebui/default.nix        
        ../../modules/services/searxng/default.nix
        ../../modules/services/docling.nix
        ../../modules/services/tailscale.nix
        
        ../../modules/services/hermes/default.nix
        ./hermes_profiles.nix

        ../../modules/llama.cpp/default_homeserver.nix
        ./endpoints.nix
    ];

    networking.hostName = "homeserver";

    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
        open = false;
    };

    services.homelab-backup = {
        enable = true;
        passwordFile = config.age.secrets."restic-homeserver".path;
    };

    # docling on GPU 0, capped at ~3 GB so it cannot evict the llama.cpp
    # server that already holds ~7.7 GB of that card.  GPU 0 is the 1080 Ti
    # (11 GB) -- the 1070 Ti has less headroom left.  See the module for why
    # the image is pinned to the cu126 line on Pascal hardware.
    services.docling = {
        enable = true;
        gpu = "0";
        memoryFraction = "0.24";
    };

    system.stateVersion = "26.05";
}
