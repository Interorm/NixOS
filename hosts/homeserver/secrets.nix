{
    config,
    inputs,
    pkgs,
    ...
}: {
    # Adding a machine secret is three steps: add a rule to
    # secrets/secrets.nix, run `agenix -e secrets/<name>.age`, then declare it
    # under `age.secrets` below and consume it by `.path` (never by value).

    environment.systemPackages = [
        inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];

    # Identity the host decrypts with.  This is also agenix' default when
    # openssh is enabled, but stated explicitly because it is load-bearing: if
    # this key is ever regenerated (reinstall, new disk), every secret must be
    # rekeyed with `agenix -r` or activation fails to decrypt.
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # --- restic backup repository password -----------------------------------
    # COMMENTED until the .age file exists: an age.secrets entry pointing at a
    # missing file breaks the build.  To switch backups on:
    #
    #   1. head -c 32 /dev/urandom | base64      # generate, SAVE IT OFF-BOX
    #   2. agenix -e secrets/restic-homeserver.age   # paste it, save, quit
    #   3. uncomment this block AND the services.homelab-backup block in
    #      hosts/homeserver/default.nix
    #   4. sudo nixos-rebuild switch --flake .#homeserver
    #
    # Lose this password and every snapshot is permanently unreadable.
    #
    # age.secrets."restic-homeserver" = {
    #     file = ../../secrets/restic-homeserver.age;
    #     owner = "root";
    #     group = "root";
    #     mode = "0400";
    # };
}
