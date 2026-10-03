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
        package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.stable;
        open = lib.mkDefault true;

        modesetting.enable = true;
        nvidiaSettings = true;

        powerManagement.enable = false;
    };
}
