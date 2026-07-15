{
    pkgs,
    ...
}:  {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [ onedrive ]

    services.onedrive.enable = true;
}