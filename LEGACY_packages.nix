{
    pkgs,
    ...
}:  {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
        direnv
        iputils pciutils
        (btop.override {cudaSupport = true;})
        yazi



        vscode
        python3
        cmake

        firefox-bin
        discord-ptb
        onedrive
    ];


    programs.firefox.enable = true;
    services.onedrive.enable = true;
    services.openssh.enable = true;
    virtualisation.docker.enable = true;
}