{
    pkgs, lib,
    ...
}: {

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    imports = [
        ./hardware-configuration.nix
        ../modules
        ../modules/desktop
        ../modules/nvidia

        ./users/users.nix

        ../modules/development/vscode.nix
        ../modules/development/remote-desktop.nix
        ../services/tailscale.nix

        ../modules/apps
        ../modules/gaming

        ../services/inference/ninfer
    ];

    networking.hostName = "Karls-PC";

    environment.systemPackages = [
        inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    environment.systemPackages = [
        (import ../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];

    system.stateVersion = "26.05";
}
