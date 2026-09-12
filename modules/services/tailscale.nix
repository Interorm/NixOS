{
    config, pkgs, lib,
    ...
}: let
    hostname = config.networking.hostName;

    # The whole attribute-path segment must be one interpolation.  Writing
    # `age.secrets.tailscale-${hostname}` is a syntax error: Nix does not allow
    # a literal prefix glued to `${...}` in an attribute path.  Binding the
    # complete name first and using `${secretName}` is the legal form.
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
}
