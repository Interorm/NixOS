{
    pkgs, lib, inputs,
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

        ./inference.nix
    ];

    networking.hostName = "Karls-PC";

    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    environment.systemPackages = [
        inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

        (import ../modules/python-envs/env_ML.nix { inherit pkgs; }).base

        pkgs.efibootmgr
        (pkgs.writeShellScriptBin "boot-windows" ''
            set -euo pipefail
            sudo efibootmgr --bootnext 0000
            sudo reboot
        '')
    ];

    system.stateVersion = "26.05";
}
