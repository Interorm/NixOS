{
    pkgs, config, lib,
    ...
}: {

    imports = [
        # Essentials
        ./hardware-configuration.nix
        ../../modules/default.nix

        # CUDA
        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix

        # Important globals
        ./users.nix
        ./secrets.nix

        # Backups
        ../../modules/services/backup.nix

        # Dev
        ../../modules/development/lean-math.nix

        # Access for other Users
        ../../modules/services/tailscale.nix
        
        # Minecraft Servers
        ../../modules/services/minecraft/crafty.nix
        
        # Hermes and AI
        ../../modules/services/hermes/default.nix
        ../../hermes/default.nix
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
