{
    pkgs, config, lib,
    ...
}: {

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    imports = [
        ./hardware-configuration.nix
        ../modules
        ../modules/nvidia

        ./users.nix
        ./secrets.nix
        ../services/backup.nix

        ../services/tailscale.nix
        
        # Minecraft Servers
        ../../modules/services/minecraft
        
        # Hermes and AI
        ./hermes
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
