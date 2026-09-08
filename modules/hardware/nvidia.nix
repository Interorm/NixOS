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
        # mkDefault: a host that needs a different branch (the homeserver's
        # Pascal cards need legacy_580) can simply override these.  Without
        # mkDefault, two plain definitions of the same option are a conflict
        # and evaluation fails.
        package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.stable;
        open = lib.mkDefault true;

        modesetting.enable = true;
        nvidiaSettings = true;

        powerManagement.enable = false;
    };
}
