{
    config, pkgs, 
    ...
}: let
    hostname = config.networking.hostName;
in {
    environment.systemPackages = with pkgs; [
        tailscale
    ];

    age.secrets.tailscale-${hostname} = {
        file = ./secrets/tailscale-${hostname}.age;
        owner = "root";
        mode = "0400";
    };

    services.tailscale = {
        enable = true;
        authKeyFile = config.age.secrets.tailscale-${hostname}.path;
    };
}