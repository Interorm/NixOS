{
    config,
    lib,
    inputs,
    pkgs,
    ...
}: let
    cfg = config.services.agenix-secrets;
in {
    # agenix wiring for this host.  The upstream NixOS module (added to the
    # host's module list in flake.nix) provides `age.secrets`; this module is
    # the house style around it: it declares WHICH secrets exist, who owns the
    # decrypted file, and puts the CLI on PATH so secrets can be edited on the
    # box.
    #
    # How it works:
    #   * secrets/*.age are encrypted blobs, committed to the repo.  Safe to
    #     publish: only the private keys listed in secrets/secrets.nix can open
    #     them.
    #   * At activation the host decrypts them with its SSH *host* key
    #     (age.identityPaths) into /run/agenix/<name> -- a tmpfs, so plaintext
    #     never touches disk.
    #   * `owner`/`mode` decide who can read the decrypted file.
    #
    # Adding a secret is three steps: add a rule to secrets/secrets.nix, run
    # `agenix -e secrets/<name>.age`, then declare it under `secrets` below.

    options.services.agenix-secrets = {
        enable = lib.mkEnableOption "agenix-managed secrets for this host";

        hermesAgents = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "karl" "joni" ];
            description = ''
                Hermes agents whose env file is managed by agenix.  For each
                name N, secrets/hermes-N.age is decrypted to /run/agenix/
                hermes-N, owned by N and readable only by them -- the same
                shape as the hand-made ${"/etc/hermes"}/N.env it replaces.

                Point the agent at it with:
                  services.hermes-agents.agents.N.environmentFile =
                      config.age.secrets."hermes-N".path;
            '';
        };
    };

    config = lib.mkIf cfg.enable {
        # The CLI, so `agenix -e secrets/foo.age` works on the box itself.
        environment.systemPackages = [
            inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];

        # Identity the host decrypts with.  This is the default when openssh is
        # enabled, but stated explicitly: if this key is ever regenerated,
        # every secret must be rekeyed (`agenix -r`) or activation fails.
        age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

        # One secret per Hermes agent, owned by that agent.
        age.secrets = lib.listToAttrs (map (agent: {
            name = "hermes-${agent}";
            value = {
                file = ../../../secrets/hermes-${agent}.age;
                owner = agent;
                group = agent;
                # 0400: the agent's gateway reads it; nobody else, not even
                # the other agent.
                mode = "0400";
            };
        }) cfg.hermesAgents);
    };
}
