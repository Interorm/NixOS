{
    config, options, lib, inputs,
    ...
}: let
    cfg = config.services.hermes-agents;

    # Hermes' own NixOS module (`services.hermes-agent`) is a singleton: one
    # `enable`, one user, one stateDir.  It cannot give you an agent per
    # person.  Its Home Manager module can, because Home Manager is already
    # per-user -- so this module turns each entry in `agents` into a Unix user
    # plus a Home Manager configuration that runs one gateway as that user.
    #
    # Nothing in `mkHome` differs between agents except what the submodule
    # exposes.  That sameness is deliberate: the hermes package (including the
    # `dependencyGroups` extras, which are baked in at build time) is ONE
    # derivation, and every agent's profile symlinks to it.
    mkHome = name: agent: { ... }: {
        imports = [ inputs.hermes-agent.homeManagerModules.default ];

        home.username = name;
        home.homeDirectory = "/home/${name}";
        home.stateVersion = config.system.stateVersion;

        # The CLI on the user's PATH with HERMES_HOME exported, so
        # `sudo -iu <name> hermes chat` talks to the same state the gateway
        # does.  The `-i` matters: a login shell is what loads
        # home.sessionVariables.
        programs.hermes-agent.enable = true;

        services.hermes-agent = {
            enable = true;
            gateway.enable = true;

            # Merged into ~/.hermes/.env at activation.  The activation unit
            # runs as the user, so the file must be readable by them -- see
            # the `environmentFile` option for the expected mode.
            environmentFiles = [ agent.environmentFile ];

            extraDependencyGroups = cfg.dependencyGroups;
            extraPackages = agent.extraPackages;

            # Rendered to config.yaml.  `${OPENAI_API_KEY}` is written
            # literally (note the backslash) and resolved by hermes from .env
            # at runtime, so no secret ever reaches the Nix store.
            settings = lib.recursiveUpdate {
                model = {
                    provider = "openai";
                    base_url = cfg.modelBaseUrl;
                    default = agent.model;
                    api_key = "\${OPENAI_API_KEY}";
                };
            } agent.settings;

            # SOUL.md is only honoured from HERMES_HOME, not from the
            # workspace -- hence hermesHomeFiles and not `documents`.
            hermesHomeFiles = lib.optionalAttrs (agent.soul != null) {
                "SOUL.md" = agent.soul;
            };
        };
    };

    agentSubmodule = lib.types.submodule ({ name, ... }: {
        options = {
            model = lib.mkOption {
                type = lib.types.str;
                default = cfg.defaultModel;
                defaultText = lib.literalExpression "config.services.hermes-agents.defaultModel";
                description = "Model id this agent asks the gateway for.";
            };

            soul = lib.mkOption {
                type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
                default = null;
                example = "You are a terse ops assistant for a homelab.";
                description = ''
                    Contents (string) or source file (path) of SOUL.md -- the
                    agent's identity.  null leaves whatever is on disk alone.
                '';
            };

            environmentFile = lib.mkOption {
                type = lib.types.str;
                default = "${cfg.secretsDir}/${name}.env";
                defaultText = lib.literalExpression ''"''${config.services.hermes-agents.secretsDir}/<name>.env"'';
                description = ''
                    KEY=value file with this agent's secrets.  It is NOT in the
                    repo -- anything in the flake is world-readable in
                    /nix/store.  Create it out of band, owned by the agent user
                    and readable only by them:

                        sudo install -m 0400 -o ${name} -g ${name} /dev/stdin ${cfg.secretsDir}/${name}.env <<'ENV'
                        OPENAI_API_KEY=empty-key
                        TELEGRAM_BOT_TOKEN=123456:ABC...
                        TELEGRAM_ALLOWED_USERS=<numeric telegram user id>
                        ENV

                    OPENAI_API_KEY is required by the config schema but the
                    local gateway ignores its value.  Hermes enables a
                    messaging platform when it finds that platform's token in
                    .env; DISCORD_BOT_TOKEN / DISCORD_ALLOWED_USERS work the
                    same way.  If a platform does not come up, add
                    `settings.platforms.telegram.enabled = true` explicitly.
                '';
            };

            settings = lib.mkOption {
                type = lib.types.attrs;
                default = {};
                example = lib.literalExpression ''
                    {
                      memory = { memory_enabled = true; };
                      agent.max_turns = 40;
                    }
                '';
                description = ''
                    Extra config.yaml keys, deep-merged over the module's
                    defaults (so `model.default` here overrides `model`).
                    `nix build github:NousResearch/hermes-agent#configKeys`
                    lists every valid leaf.
                '';
            };

            extraPackages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [];
                example = lib.literalExpression "[ pkgs.pandoc pkgs.jq ]";
                description = "Tools the agent may call from its terminal.";
            };

            extraGroups = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                example = [ "docker" ];
                description = ''
                    Supplementary groups for the agent's Unix user.  Think
                    before adding `docker` -- that is root-equivalent, and the
                    agent runs arbitrary shell commands.
                '';
            };
        };
    });
in {
    options.services.hermes-agents = {
        enable = lib.mkEnableOption "per-user Hermes agents via Home Manager";

        modelBaseUrl = lib.mkOption {
            type = lib.types.str;
            # Point at the unified gateway when this host runs one, so every
            # agent sees every backend (coder, chat, the PC when awake) under
            # one URL.  The `options ?` guard keeps this module evaluable on a
            # host that does not import model-gateway.nix.
            default =
                if options.services ? model-gateway
                then "http://127.0.0.1:${toString config.services.model-gateway.port}/v1"
                else "http://127.0.0.1:8080/v1";
            defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.services.model-gateway.port}/v1"'';
            description = "OpenAI-compatible base URL every agent talks to.";
        };

        defaultModel = lib.mkOption {
            type = lib.types.str;
            example = "Qwen3.5-9B";
            description = ''
                Model id used by agents that do not set their own.  Must be an
                id the gateway lists at /v1/models -- i.e. the `--alias` a
                llama-server was started with.
            '';
        };

        secretsDir = lib.mkOption {
            type = lib.types.str;
            default = "/etc/hermes";
            description = "Directory holding one <name>.env per agent.";
        };

        dependencyGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "messaging" ];
            description = ''
                Hermes pyproject extras compiled into the venv.  "messaging"
                is Discord + Telegram + Slack.  Build-time, not runtime: on
                Nix the store is read-only, so a missing extra cannot be pip
                installed later.  Shared by all agents so there is one build.
            '';
        };

        agents = lib.mkOption {
            type = lib.types.attrsOf agentSubmodule;
            default = {};
            description = ''
                One agent per attribute.  The attribute name IS the Unix user
                name that owns the agent.  These users are created with no
                password and no SSH key, so nobody can log in as them; they
                exist only to own a HERMES_HOME and a systemd user service.
            '';
        };
    };

    # Requires the home-manager NixOS module in the host's module list; without
    # it `home-manager.users` is not a declared option and evaluation stops
    # with a message that says exactly that.
    config = lib.mkIf cfg.enable {
        systemd.tmpfiles.rules = [
            "d ${cfg.secretsDir} 0755 root root - -"
        ];

        users.groups = lib.mapAttrs (_: _: {}) cfg.agents;

        users.users = lib.mapAttrs (name: agent: {
            isNormalUser = true;
            description = "Hermes agent (${name})";
            group = name;
            extraGroups = agent.extraGroups;

            # Without linger the user manager -- and the gateway with it --
            # is torn down the moment the account has no session.  An account
            # that never logs in never has a session, so this is not optional.
            linger = true;
        }) cfg.agents;

        home-manager.users = lib.mapAttrs mkHome cfg.agents;
    };
}
