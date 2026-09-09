{
    pkgs, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/hardware/display.nix
        ../../modules/hardware/sound.nix

        ../../modules/default.nix
        ./users.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix
        ../../modules/development/vscode.nix
        ../../modules/development/remote-desktop.nix

        ../../modules/apps/default.nix
        ../../modules/apps/default_gaming.nix

        ../../modules/llama.cpp/llama-server.nix
        ../../modules/llama.cpp/huggingface-models.nix
        ../../modules/llama.cpp/dnd-toggle.nix
    ];

    # Was `network.hostName` -- no such option path exists.
    networking.hostName = "Karls-PC";

    environment.systemPackages = [
        (import ../../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];

    # NOT a version to bump.  See the note in hosts/homeserver/default.nix.
    system.stateVersion = "26.05";
}
