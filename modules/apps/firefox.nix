{
    pkgs,
    ...
}:  {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [ firefox ];

    programs.firefox.enable = true;
}