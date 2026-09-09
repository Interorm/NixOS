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

        openssh.authorizedKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPootR7FogHsp0OdnDu6kjPj2rqHribx0OnFvzyfnYGY root@homeserver"
        ];
    };
}
