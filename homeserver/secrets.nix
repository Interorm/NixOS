{
    config,
    inputs,
    pkgs,
    ...
}: {
    environment.systemPackages = [
        inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];

    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    age.secrets."restic-homeserver" = {
        file = ../secrets/restic-homeserver.age;
        owner = "root";
        group = "root";
        mode = "0400";
    };
}
