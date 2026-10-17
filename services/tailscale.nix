{
    config, pkgs, lib,
    ...
}: let
    hostname = config.networking.hostName;

    secretName = "tailscale";
in {
    environment.systemPackages = [ pkgs.tailscale ];

    age.secrets.${secretName} = {
        file = ../secrets/${secretName}.age;
        owner = "root";
        mode = "0400";
    };

    services.tailscale = {
        enable = true;
        authKeyFile = config.age.secrets.${secretName}.path;
    };

    networking.firewall = {
        trustedInterfaces = [ "tailscale0" ];
        allowedUDPPorts = [ config.services.tailscale.port ];
    };
}
