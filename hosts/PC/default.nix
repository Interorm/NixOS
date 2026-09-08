{
    pkgs, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix

        ../../modules/hardware/nvidia.nix

        ../../modules/hardware/display.nix
        ../../modules/hardware/sound.nix

        ../../modules/development/cuda.nix
        ../../modules/development/vscode.nix

        ../../modules/apps/default.nix
        ../../modules/apps/default_gaming.nix

        # NInfer + Qwen3.8-27B.  PC only -- the homeserver's Pascal cards cannot
        # run it (NInfer builds for sm_120a exclusively).
        ../../modules/services/llama.cpp/llama-server.nix
        ../../modules/services/huggingface-models.nix
        ../../modules/services/llama.cpp/dnd-toggle.nix
    ];

    # Was `network.hostName` -- no such option path exists.
    networking.hostName = "Karls-PC";

    environment.systemPackages = [
        (import ../../modules/python-envs/env_ML.nix { inherit pkgs; }).base
    ];

    # NOT a version to bump.  See the note in hosts/homeserver/default.nix.
    system.stateVersion = "26.05";
}
