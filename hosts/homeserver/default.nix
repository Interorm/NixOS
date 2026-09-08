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

        ../../modules/services/llama.cpp/llama-proxy.nix
        ../../modules/services/llama.cpp/llama-coder.nix
        ../../modules/services/llama.cpp/llama-server.nix
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
        8000 8070 8080 8090
        2000
        25565 25566 25567 25568 25569
    ];

    environment.systemPackages = with pkgs; [
        wakeonlan
        tmux
        git-lfs
        python3Packages.huggingface-hub
    ];

    # NOT a version to bump: it pins the on-disk state formats (postgres major,
    # etc.) that this host was first installed with.  Leave it alone forever.
    system.stateVersion = "26.05";
}
