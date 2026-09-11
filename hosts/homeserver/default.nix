{
    pkgs, config, lib,
    ...
}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix
        ../../modules/development/lean-math.nix

        ../../modules/services/minecraft/crafty.nix

        ../../modules/services/openwebui/default.nix        
        ../../modules/services/hermes/default.nix
        ./hermes_profiles.nix

        ./endpoints.nix
        ../../modules/llama.cpp/model-gateway.nix
        ../../modules/llama.cpp/llama-proxy.nix
        ../../modules/llama.cpp/llama-coder.nix
        ../../modules/llama.cpp/llama-chat.nix
        ../../modules/llama.cpp/huggingface-models.nix
    ];

    networking.hostName = "homeserver";

    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
        open = false;
    };

    # Ported from the pre-flake configuration.nix; modules/hardware/networking.nix
    # only opens 22.
    networking.firewall.allowedTCPPorts = [
        2000 25565 25566 25567 25568 25569
    ];

    system.stateVersion = "26.05";
}
