{
    pkgs,
    ...
}: {
    users.users."karl" = {
        isNormalUser = true;
        description = "Karl";
        extraGroups = [ "networkmanager" "wheel" "docker" ];
        packages = with pkgs; [
            kdePackages.kate
        ];
    };
}
