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

        # Home Manager only injects home.sessionVariables (HERMES_HOME among
        # them) into a shell it manages.  Without this, an SSH login gets a
        # bare bash and `hermes` falls back to the default ~/.hermes -- the
        # same directory, but only by coincidence, and HERMES_MANAGED is lost.
        programs.bash.enable = true;

        services.hermes-agent = {
            enable = true;
            gateway.enable = true;

            # Merged into ~/.hermes/.env at activation.  The activation unit
            # runs as the user, so the file must be readable by them -- see
            # the `environmentFile` option for the expected mode.
            environmentFiles = [ agent.environmentFile ];

            # Non-secret env vars, merged into the same .env.  Hermes documents
            # the api_server switches as env vars and gives them precedence
            # over config.yaml, so this is the reliable path.  The bearer key
            # (API_SERVER_KEY) is a secret and stays in environmentFile.
            environment = lib.optionalAttrs (agent.apiServerPort != null) {
                API_SERVER_ENABLED = "true";
                API_SERVER_PORT = toString agent.apiServerPort;
                # 0.0.0.0, not loopback: the point is other machines -- and
                # docker containers reach the host via the bridge IP, which
                # a 127.0.0.1 bind would refuse too.  Auth is the bearer key.
                API_SERVER_HOST = "0.0.0.0";
            } // lib.optionalAttrs agent.dashboard.enable {
                # The dashboard's auth gate (on for any non-loopback bind)
                # takes username/password from .env.  The username is not a
                # secret, so it is fixed here to the Unix user name; the
                # password and the cookie secret live in environmentFile.
                HERMES_DASHBOARD_BASIC_AUTH_USERNAME = name;
            };

            extraDependencyGroups = cfg.dependencyGroups;
            extraPackages = agent.extraPackages;

            # Fleet-wide servers first, per-agent second.  `//` is a shallow
            # merge: a per-agent server with the same name replaces the
            # fleet-wide one outright, which is what you want when one person
            # needs the same server with different args.
            mcpServers = cfg.mcpServers // agent.mcpServers;

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

            # `hermes dashboard` is a superset of `hermes serve`: the /api/ws
            # socket the desktop app attaches to, plus the browser panel, on
            # one port.  It runs as a second user unit (hermes-backend)
            # beside the gateway and shares its HERMES_HOME, so both see the
            # same sessions and memory.
            #
            # The bind address is deliberately NOT loopback: the point is
            # other machines.  That switches on Hermes' auth gate (basic auth
            # from .env, see `environment` above) and a Host-header check
            # that only accepts the exact address bound to -- hence
            # dashboardHost must be what clients type, never "homeserver",
            # which NixOS resolves to 127.0.0.2 in /etc/hosts.
            backend = lib.mkIf agent.dashboard.enable {
                mode = "dashboard";
                port = agent.dashboard.port;
                host = lib.mkIf (cfg.dashboardHost != null) cfg.dashboardHost;
                sessionTokenFile = agent.dashboard.sessionTokenFile;

                # Interface mode: poll until the NIC has an IPv4, bind to
                # that, ignore `host`.  For DHCP boxes with no stable name.
                waitFor = lib.mkIf (cfg.dashboardInterface != null) "interface";
                interfaceName = cfg.dashboardInterface;
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

            sshKeys = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                example = [ "ssh-ed25519 AAAA... alice@laptop" ];
                description = ''
                    Public keys that may SSH in as this agent's user.  Empty
                    (the default) keeps the account login-locked.  With a key,
                    the person can `ssh <name>@homeserver` and run `hermes
                    chat`, inspect ~/.hermes, or read the gateway journal with
                    `journalctl --user -u hermes-agent`.  Password login stays
                    off regardless.
                '';
            };

            dashboard = {
                enable = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = ''
                        Run `hermes dashboard` for this agent, reachable from
                        the LAN at http://<dashboardHost>:<port>.  Serves both
                        the browser panel and the socket Hermes Desktop
                        attaches to (Settings -> Gateways -> Remote gateway).
                        On by default; set false for a messaging-only agent.
                    '';
                };

                port = lib.mkOption {
                    type = lib.types.port;
                    example = 9119;
                    description = ''
                        TCP port, opened in the firewall.  No default on
                        purpose: every agent needs its own, and a computed
                        default would silently renumber everyone's URL when
                        an agent is added.  Pick them by hand, e.g. 9119,
                        9120, ...
                    '';
                };

                sessionTokenFile = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "/etc/hermes/${name}.token";
                    description = ''
                        Optional.  A file holding one raw token, mode 0600,
                        owned by ${name}.  Without it the backend mints a new
                        session token on every start, so a token pasted into
                        the desktop app stops working after a restart.  With
                        basic auth (the default here) users sign in with
                        username/password instead and never touch the token,
                        so most setups can leave this null.
                    '';
                };
            };

            # The gate needs these two in ${cfg.secretsDir}/${name}.env when
            # dashboard.enable is true (the username is set by the module):
            #
            #     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<choose one>
            #     HERMES_DASHBOARD_BASIC_AUTH_SECRET=<openssl rand -base64 32>
            #
            # SECRET signs the login cookie; without it every restart logs
            # everyone out.  Hermes also accepts
            # HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH (scrypt) in place of
            # the plaintext password.

            apiServerPort = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                example = 8642;
                description = ''
                    Expose this agent as an OpenAI-compatible API on
                    0.0.0.0:<port> (firewall opened) so any OpenAI-speaking
                    client -- a terminal chat tool on another machine, or
                    OpenWebUI -- can talk to the agent at
                    http://homeserver:<port>/v1 with model "hermes-agent".

                    Requires API_SERVER_KEY=<random> in the agent's env file;
                    generate one with `openssl rand -hex 32`.  Clients send it
                    as `Authorization: Bearer <key>`.  Every agent needs its
                    own port.  Requests are stateless unless the client sends
                    an X-Hermes-Session-Id header; the agent's memory persists
                    either way.
                '';
            };

            mcpServers = lib.mkOption {
                type = lib.types.attrsOf lib.types.attrs;
                default = {};
                example = lib.literalExpression ''
                    {
                      github = {
                        command = "npx";
                        args = [ "-y" "@modelcontextprotocol/server-github" ];
                        env.GITHUB_PERSONAL_ACCESS_TOKEN = "\''${GITHUB_TOKEN}";
                      };
                    }
                '';
                description = ''
                    MCP servers for this agent only, merged over the
                    fleet-wide `services.hermes-agents.mcpServers`.  Same
                    shape as Hermes' own `mcpServers.<name>` option: stdio
                    servers take `command`/`args`/`env`, HTTP servers take
                    `url`/`headers`.  Secrets go in the agent's env file and
                    are referenced as `''${VAR}` -- Hermes resolves them at
                    runtime.
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

        dashboardHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "192.168.42.2";
            description = ''
                Address every agent's dashboard binds to, and therefore the
                address clients must use -- Hermes rejects any request whose
                Host header differs from it (DNS-rebinding defence).  Use the
                LAN IP or a name that resolves to it *from the clients*.  Not
                the bare hostname: NixOS maps that to 127.0.0.2 in
                /etc/hosts, which would bind loopback and expose nothing.

                Required when any agent has dashboard.enable, unless
                dashboardInterface is set instead.
            '';
        };

        dashboardInterface = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "enp3s0";
            description = ''
                Alternative to dashboardHost for machines without a stable
                address: wait until this interface holds an IPv4, then bind
                to whatever it is.  Clients must then use that address.
                Overrides dashboardHost when set.
            '';
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

        mcpServers = lib.mkOption {
            type = lib.types.attrsOf lib.types.attrs;
            default = {};
            example = lib.literalExpression ''
                {
                  searxng = {
                    command = "npx";
                    args = [ "-y" "mcp-searxng" ];
                    env.SEARXNG_URL = "http://127.0.0.1:3030";
                  };
                }
            '';
            description = ''
                MCP servers every agent gets.  Per-agent `mcpServers` are
                merged on top and win on name collision.  `npx` works out of
                the box because the hermes package wraps Node.js into its
                PATH; for `uvx`-based servers add `pkgs.uv` to the agent's
                `extraPackages`.
            '';
        };

        agents = lib.mkOption {
            type = lib.types.attrsOf agentSubmodule;
            default = {};
            description = ''
                One agent per attribute.  The attribute name IS the Unix user
                name that owns the agent.  The account gets no password; it is
                reachable only via `sshKeys`, and with none set nobody can log
                in at all -- the user then exists purely to own a HERMES_HOME
                and a systemd user service.
            '';
        };
    };

    # Requires the home-manager NixOS module in the host's module list; without
    # it `home-manager.users` is not a declared option and evaluation stops
    # with a message that says exactly that.
    config = let
        # Every TCP port any agent binds, dashboards and API servers together
        # -- they share one host, so they must not share a number.
        agentList = lib.attrValues cfg.agents;
        apiPorts = lib.filter (p: p != null) (map (a: a.apiServerPort) agentList);
        dashPorts = map (a: a.dashboard.port) (lib.filter (a: a.dashboard.enable) agentList);
        allPorts = dashPorts ++ apiPorts;
    in lib.mkIf cfg.enable {
        assertions = [
            {
                # Two services on one port would race for the bind and the
                # loser would crash-loop under Restart=always, silently.
                assertion = lib.length allPorts == lib.length (lib.unique allPorts);
                message = "services.hermes-agents: two agents share a dashboard.port or apiServerPort.";
            }
            {
                # Without either, the backend would bind Hermes' default
                # 127.0.0.1 -- reachable from nowhere, with no error.
                assertion = dashPorts == [] || cfg.dashboardHost != null || cfg.dashboardInterface != null;
                message = "services.hermes-agents: an agent has dashboard.enable but neither dashboardHost nor dashboardInterface is set.";
            }
        ];

        # Dashboards are LAN-facing by design; the auth gate is the lock.
        networking.firewall.allowedTCPPorts = allPorts;

        systemd.tmpfiles.rules = [
            "d ${cfg.secretsDir} 0755 root root - -"
        ];

        users.groups = lib.mapAttrs (_: _: {}) cfg.agents;

        users.users = lib.mapAttrs (name: agent: {
            isNormalUser = true;
            description = "Hermes agent (${name})";
            group = name;
            extraGroups = agent.extraGroups;

            # The only door into the account.  No hashedPassword is set
            # anywhere, so an empty list means the account is fully locked.
            openssh.authorizedKeys.keys = agent.sshKeys;

            # Without linger the user manager -- and the gateway with it --
            # is torn down the moment the account has no session.  An account
            # that never logs in never has a session, so this is not optional.
            linger = true;
        }) cfg.agents;

        home-manager.users = lib.mapAttrs mkHome cfg.agents;
    };
}
