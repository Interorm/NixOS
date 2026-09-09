{
    pkgs,
    ...
}: {
    # Ported from the pre-flake hosts/homeserver/configuration.nix.  The flake
    # tree defined no users at all for this host, which means nobody could log
    # in after a switch.
    users.users."homeserver" = {
        isNormalUser = true;
        description = "homeserver";

        extraGroups = [ "networkmanager" "wheel" "docker" ];
        packages = with pkgs; [];

        openssh.authorizedKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
        ];
    };

    users.groups.homeserver = {};
}
