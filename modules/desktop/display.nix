{
    pkgs,
    ...
}: {
    services = {
        desktopManager.plasma6.enable = true;
        displayManager.sddm = {
            enable = true;
            wayland.enable = true;
        };

        # Fallback for X11
        xserver = {
            enable = true;
            xkb.layout = "de";
            xkb.variant = "";
        };
    };

    environment.plasma6.excludePackages = with pkgs.kdePackages; [
        qrca
        elisa
    ];
}
