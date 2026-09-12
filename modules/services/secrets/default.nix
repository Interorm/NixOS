{
    config,
    lib,
    inputs,
    pkgs,
    ...
}: {
    # Machine-level agenix wiring.  Per-AGENT secrets are NOT here: they are
    # derived automatically from `services.hermes-agents.agents` in
    # modules/services/hermes/hermes.nix, so adding an agent creates its secret
    # with no further wiring.  This module covers the rest:
    #
    #   * the agenix CLI on PATH, so secrets can be edited on the box
    #   * the identity the host decrypts with
    #   * secrets owned by the machine rather than by a person (Tailscale,
    #     service credentials, ...)
    #
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

    # --- machine-level secrets ---------------------------------------------
    # Commented out until the .age file exists -- an age.secrets entry pointing
    # at a missing file breaks the build.  Uncomment together with creating it.
    #
    # age.secrets.tailscale-authkey = {
    #     file = ../../../secrets/tailscale-authkey.age;
    #     owner = "root";
    #     mode = "0400";
    # };
    #
    # ...then consume it:
    # services.tailscale = {
    #     enable = true;
    #     authKeyFile = config.age.secrets.tailscale-authkey.path;
    # };
}
