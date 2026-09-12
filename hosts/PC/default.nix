{
    pkgs, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/hardware/default_desktop.nix

        ../../modules/default.nix
        ./users.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix
        ../../modules/development/vscode.nix
        ../../modules/development/remote-desktop.nix

        ../../modules/apps/default.nix
        ../../modules/apps/default_gaming.nix

        ../../modules/llama.cpp/default_workstation.nix
    ];

    # Was `network.hostName` -- no such option path exists.
    networking.hostName = "Karls-PC";

    environment.systemPackages = [
        (import ../../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];

    # NOT a version to bump.  See the note in hosts/homeserver/default.nix.
    system.stateVersion = "26.05";
}
