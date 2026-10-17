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
        ../services/backup.nix

        ../services/tailscale.nix
        
        # Minecraft Servers
        ../services/minecraft
        
        # Hermes and AI
        ./hermes
        ./inference.nix
    ];

    networking.hostName = "homeserver";

    environment.systemPackages = [
        inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

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
