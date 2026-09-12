{
    pkgs,
    ...
}: {
    users.users."homeserver" = {
        isNormalUser = true;
        description = "homeserver";

        extraGroups = [ "networkmanager" "wheel" "docker" ];
        packages = with pkgs; [];

        openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
        ];
    };

    users.groups.homeserver = {};
}
