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

        ./users.nix

        ../modules/development/vscode.nix
        ../modules/development/remote-desktop.nix

        ../modules/apps
        ../modules/gaming

        ../services/inference/ninfer
    ];

    networking.hostName = "Karls-PC";

    

    environment.systemPackages = [
        (import ../../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];

    system.stateVersion = "26.05";
}
