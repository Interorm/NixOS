{...}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix

        ../../modules/development/vscode.nix
        ../../modules/python-envs/env_ML.nix

        ../../modules/apps/default.nix
    ];

    network.hostname = "Karls-PC";
}