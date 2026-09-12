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
    age.identityPaths = [ "/root/.ssh/id_ed25519" ];

}
