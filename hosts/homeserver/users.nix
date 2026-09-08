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
    };

    users.groups.homeserver = {};
}
