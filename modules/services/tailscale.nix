{
    config, pkgs, lib,
    ...
}: let
    hostname = config.networking.hostName;

    secretName = "tailscale-${hostname}";
in {
    environment.systemPackages = [ pkgs.tailscale ];

    # Path is relative to THIS file (modules/services/), so ../../ reaches the
    # repo root.  One auth key per host: a second machine needs its own
    # secrets/tailscale-<host>.age plus a rule in secrets/secrets.nix, or its
    # build fails on the missing file.
    age.secrets.${secretName} = {
        file = ../../secrets/${secretName}.age;
        owner = "root";
        mode = "0400";
    };

    services.tailscale = {
        enable = true;
        authKeyFile = config.age.secrets.${secretName}.path;
    };

    networking.firewall = {
        trustedInterfaces = [ "tailscale0" ];
        allowedUDPPorts = [ config.services.tailscale.port ]
    }
}
