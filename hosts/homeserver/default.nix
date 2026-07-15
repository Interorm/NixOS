{...}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ../../modules/hardware/nvidia.nix
        ../../modules/development/cuda.nix

        ../../modules/services/llama.cpp/llama-proxy.nix
        ../../modules/services/llama.cpp/llama-coder.nix
    ];

    network.hostname = "homeserver";

    # Legacy drivers for 1080/70Ti
    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
        open = false;
    };
}