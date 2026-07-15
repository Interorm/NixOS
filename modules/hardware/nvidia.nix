{
    config,
    pkgs,
    lib,
    ...
}: {
    nixpkgs.config.allowUnfree = true;

    hardware.graphics = {
        enable = true;
        enable32Bit = true;
    };

    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        open = true;

        modesetting.enable = true;
        nvidiaSettings = true;

        powerManagement.enable = false;
    };
}
