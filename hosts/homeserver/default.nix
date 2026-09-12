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

    system.stateVersion = "26.05";
}
