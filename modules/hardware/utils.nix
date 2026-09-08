{
    pkgs,
    ...
}: {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
        direnv
        pciutils
        (btop.override {cudaSupport = true;})
        yazi
        tmux
    ];
}