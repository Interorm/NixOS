{
    pkgs, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix

        ../../modules/development/vscode.nix

        ../../modules/apps/default.nix
    ];

    network.hostName = "Karls-PC";

    environment.systemPackages = with pkgs; [
        (import ../../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];
}