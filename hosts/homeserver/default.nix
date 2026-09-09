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

        ../../modules/llama.cpp/model-gateway.nix
        ../../modules/llama.cpp/llama-proxy.nix
        ../../modules/llama.cpp/llama-coder.nix
        ../../modules/llama.cpp/llama-chat.nix
        ../../modules/llama.cpp/huggingface-models.nix
    ];

    # Was `network.hostname` -- no such option path exists.  It is
    # `networking.hostName` (both the plural and the capital N matter).
    networking.hostName = "homeserver";

    # Legacy drivers for 1080/70Ti.  The default nvidia package in nixpkgs no
    # longer supports Pascal, hence the pin.  nvidia.nix declares these with
    # lib.mkDefault so this plain definition wins instead of colliding.
    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
        open = false;
    };

    # Ported from the pre-flake configuration.nix; modules/hardware/networking.nix
    # only opens 22.
    networking.firewall.allowedTCPPorts = [
        3000 3030 3035 3060
        8000 8080
        2000 25565 25566 25567 25568 25569
    ];

    services.model-gateway = {
        enable = true;

        host = "0.0.0.0";
        port = 8080;

        endpoints = {
            coder = { url = "http://localhost:8060"; };
            chat  = { url = "http://localhost:8070"; };

            pc = {
                url = "http://localhost:8090";
                discovery = "static";
                models = [ "Qwen3.8-27B" ]; 
                healthPath = "/proxy/status";
                timeout = 1200.0;       
            };
        };
    };


    system.stateVersion = "26.05";
}
