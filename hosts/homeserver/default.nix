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

        ../../modules/services/llama.cpp/model-gateway.nix
        ../../modules/services/llama.cpp/llama-proxy.nix
        ../../modules/services/llama.cpp/llama-coder.nix
        ../../modules/services/llama.cpp/llama-chat.nix
        ../../modules/services/huggingface-models.nix
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
            # Always-on: the gateway asks them what they serve, every 60 s.
            # `discovery` defaults to "probe", so only the URL is needed.
            coder = { url = "http://localhost:8060"; };
            chat  = { url = "http://localhost:8070"; };

            # Wake-on-demand: NEVER probe this one.  Its /v1/models goes through
            # the catch-all route, which boots the PC.  So: declared ids + a
            # liveness poll of /proxy/status, which is side-effect-free.
            pc = {
                url = "http://localhost:8090";
                discovery = "static";
                models = [ "qwen3.8-27b" ];   # see below
                healthPath = "/proxy/status";
                timeout = 1200.0;               # WoL + boot + 30 GB load ≈ 8 min
            };
        };
    };


    # NOT a version to bump: it pins the on-disk state formats (postgres major,
    # etc.) that this host was first installed with.  Leave it alone forever.
    system.stateVersion = "26.05";
}
