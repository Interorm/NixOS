{
    config, options, lib, pkgs, inputs,
    ...
}: let
    cfg = config.services.hermes-agents;

    # Interpreter carrying the Google API client libraries.  The
    # google-workspace skill shells out to `python` and imports google.auth /
    # google_auth_oauthlib / googleapiclient; on NixOS there is no pip install
    # into a read-only store, so the interpreter has to carry them.  All three
    # are prebuilt in nixpkgs -- a download, not a compile.
    googlePython = pkgs.python3.withPackages (ps: with ps; [
        google-auth
        google-auth-oauthlib
        google-api-python-client
    ]);

    # Where an agent's Google OAuth *client secret* comes from.  Mirrors
    # environmentFile: agenix when that backend is on, a plain path otherwise.
    # NOTE this is the client secret (downloaded from Cloud Console), not the
    # OAuth token -- the token is minted by the consent flow on the machine and
    # lives in ~/.hermes/google_token.json, which no deployment system can
    # pre-seed.
    googleClientSecretPath = name:
        if cfg.secretsBackend == "agenix"
        then config.age.secrets."google-${name}".path
        else "${cfg.secretsDir}/google-${name}.json";

    # The PDF -> docling hook, with its URL and timeout baked in.  A hook is
    # spawned by Hermes as a bare subprocess with no shell profile, so
    # everything it needs -- jq, curl, and the two settings -- has to be
    # closed over here rather than read from the environment.
    doclingHook = pkgs.writeShellApplication {
        name = "hermes-docling-pdf-hook";
        runtimeInputs = with pkgs; [ jq curl coreutils ];
        text = ''
            export DOCLING_URL=${lib.escapeShellArg cfg.doclingPdfHook.url}
            export DOCLING_TIMEOUT=${toString cfg.doclingPdfHook.timeout}
        '' + builtins.readFile ./docling-pdf-hook.sh;
    };

    doclingHookCommand = "${doclingHook}/bin/hermes-docling-pdf-hook";

    # Shell hooks need consent per (event, command) pair, and a gateway has no
    # TTY to ask on -- an unapproved hook is silently skipped, which for this
    # hook means PDFs quietly go back to the text-layer extractor.  The
    # alternative escape hatch, `hooks_auto_accept`, would pre-approve every
    # hook anyone ever adds; this approves exactly one store path instead, and
    # a rebuild that changes the script changes the path and so requires a new
    # approval.  Hermes still owns the file at runtime (0600, its own writes
    # are preserved between activations).
    doclingAllowlist = builtins.toJSON {
        approvals = [
            { event = "pre_tool_call"; command = doclingHookCommand; }
        ];
    };

    # The Hermes Desktop renderer rebuilt as a mobile PWA, and the agent
    # package with its web_dist pointed at it.  Evaluated lazily: an agent
    # that never sets `mobile.enable` never forces this, so the npm build is
    # only in the closure of a host that actually asked for it.
    hermesMobile = import ./hermes-mobile.nix {
        inherit lib pkgs;
        hermesUpstream = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
        inherit (cfg.mobile) rev hash;
    };

    # -- Declarative sub-profiles ---------------------------------------
    #
    # A "profile" in Hermes is just a directory under HERMES_HOME/profiles/
    # -- so dropping config.yaml/SOUL.md/profile.yaml/.env into
    # ~/.hermes/profiles/<name>/ declaratively is enough to make `hermes -p
    # <name> ...` and a Kanban dispatcher worker see a real profile.  No
    # `hermes profile create` needed: that command additionally makes a
    # `~/.local/bin/<name>` alias, which is a convenience (`hermes profile
    # alias <name>` adds one later) and not required for -p or Kanban
    # routing.
    #
    # This reimplements a small slice of what nix/moduleCommon.nix's
    # `mcpServersToConfig` and `mkConfigFiles` do for the TOP-LEVEL profile,
    # because those are internal to the upstream Home Manager module and
    # only ever render ONE config.yaml (the one at HERMES_HOME root) -- a
    # sub-profile's config.yaml has to be hand-built.  Kept to the entry
    # shapes this repo actually uses (stdio command/args/env, HTTP
    # url/headers); extend here if a profile ever needs
    # auth/sampling/tool-filtering on an MCP server.
    mkProfileMcpServerEntry = srv:
        lib.optionalAttrs (srv ? command) { inherit (srv) command; args = srv.args or []; }
        // lib.optionalAttrs (srv ? env) { inherit (srv) env; }
        // lib.optionalAttrs (srv ? url) { inherit (srv) url; }
        // lib.optionalAttrs (srv ? headers) { inherit (srv) headers; }
        // { enabled = srv.enabled or true; };

    # One profile's config.yaml.  Layered the same way the top-level
    # profile's is (module defaults < fleet-wide < the profile's own
    # `settings`), so a profile can override any leaf.
    #
    # MCP servers are NOT inherited from the agent: a profile's `mcpServers`
    # is its COMPLETE set (over the fleet-wide base, which this repo leaves
    # empty).  Inheriting the agent's would make the narrow loadouts
    # meaningless -- an orchestrator that declares `mcpServers = {}` to keep
    # its prefill minimal would silently still pay for every server the
    # top-level profile uses, and `{}` cannot subtract.  A profile that
    # genuinely wants the agent's set names the servers it wants; the
    # snippets in hermes/mcp/ make that a one-line `inherit`.
    mkProfileConfig = agent: pname: p: let
        mergedMcp = cfg.mcpServers // p.mcpServers;
    in builtins.toJSON (lib.recursiveUpdate (lib.recursiveUpdate ({
        model = {
            provider = "custom";
            base_url = cfg.modelBaseUrl;
            default = if p.model != null then p.model else agent.model;
            api_key = "\${OPENAI_API_KEY}";
        };
        # The TOP-LEVEL `toolsets` key, which is what the kanban
        # tool-availability gate reads (tools/kanban_tools.py ::
        # _profile_has_kanban_toolset) -- NOT `platform_toolsets`, which is
        # what `hermes tools enable kanban` writes and which that gate
        # ignores.  Writing it here is what actually turns kanban_* tools on
        # for a profile.  See hermes-agent issue #83042.
        toolsets = p.toolsets;
        # A profile with no MCP servers must render an EMPTY mcp_servers
        # map, not omit the key: the fleet-wide `settings` deep-merges
        # underneath, so omitting it would let a fleet-level mcp_servers
        # block (if one is ever added) leak back in.  Explicit {} wins.
        mcp_servers = lib.mapAttrs (_: mkProfileMcpServerEntry) mergedMcp;
    }) cfg.settings) p.settings);

    # hermesHomeFiles entries for one agent's sub-profiles, keyed under
    # profiles/<name>/... -- upstream's mkDocumentTree already creates parent
    # directories for keys containing "/", so nesting needs no extra work.
    mkProfileFiles = agent: lib.foldl' (acc: pname: let
        p = agent.profiles.${pname};
        base = "profiles/${pname}";
    in acc
        // { "${base}/config.yaml" = mkProfileConfig agent pname p; }
        // lib.optionalAttrs (p.soul != null) { "${base}/SOUL.md" = p.soul; }
        // lib.optionalAttrs (p.description != null) {
            # What `hermes profile describe <name> --text ...` would write.
            # The Kanban decomposer routes work by this, so a profile
            # without one is effectively invisible to routing.
            "${base}/profile.yaml" = builtins.toJSON { description = p.description; };
        }
    ) {} (lib.attrNames agent.profiles);

    profileSubmodule = lib.types.submodule ({ name, ... }: {
        options = {
            model = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                defaultText = lib.literalExpression "the parent agent's model";
                description = ''
                    Model id for this profile, as listed by the gateway at
                    /v1/models.  null inherits the parent agent's `model`.
                    Per-profile pins are how one role runs on a coder model
                    while another runs on a general one.
                '';
            };

            soul = lib.mkOption {
                type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
                default = null;
                description = ''
                    Contents (string) or source file (path) of this
                    profile's SOUL.md -- its identity.  null leaves whatever
                    is on disk alone.
                '';
            };

            description = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "Web research, document analysis, fact-checking.";
                description = ''
                    One- or two-sentence description of what this profile is
                    good at, written to profile.yaml.  Equivalent to `hermes
                    profile describe <name> --text "..."`.  The Kanban
                    decomposer reads it to route work by role rather than by
                    profile name alone -- set it on anything meant to
                    receive cards.
                '';
            };

            toolsets = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "hermes-cli" ];
                example = [ "kanban" ];
                description = ''
                    This profile's top-level `toolsets` list in config.yaml.

                    Note this is specifically the key the kanban tool-gate
                    reads, NOT `platform_toolsets` (what `hermes tools
                    enable` writes, and which that gate ignores -- upstream
                    issue #83042).  List "kanban" here to give a profile
                    kanban_* tools; the `all`/`*` wildcard deliberately does
                    not include them.

                    Omitting "hermes-cli" is a real tool-restriction
                    mechanism: an orchestrator with `[ "kanban" ]` alone
                    cannot edit files, which enforces "delegate, don't
                    implement" far better than instructions in a SOUL can.
                '';
            };

            settings = lib.mkOption {
                type = lib.types.attrs;
                default = {};
                example = lib.literalExpression ''
                    {
                      skills.external_dirs = [ "/home/karl/.agents/skills" ];
                      cron.model = "Gemma4-E4B";
                    }
                '';
                description = ''
                    Extra config.yaml keys for this profile, deep-merged over
                    the fleet-wide `settings` and the model/toolsets/
                    mcp_servers this module derives.
                '';
            };

            mcpServers = lib.mkOption {
                type = lib.types.attrsOf lib.types.attrs;
                default = {};
                description = ''
                    MCP servers for this profile.  This is the profile's
                    COMPLETE set, merged only over the fleet-wide
                    `services.hermes-agents.mcpServers` -- the parent
                    agent's servers are deliberately NOT inherited, so
                    `mcpServers = {}` really means "none" and a narrow
                    profile cannot silently pay for the agent's whole
                    loadout (`{}` cannot subtract from an inherited set).
                    Name the servers the role needs; with the snippets in
                    hermes/mcp/ that is a one-line `inherit (mcp) ...`.

                    Same entry shape as the agent-level option: stdio takes
                    command/args/env, HTTP takes url/headers.

                    Worth keeping narrow: a server's tool schemas enter the
                    prefill of every request the profile makes, so servers
                    the role never uses are a standing token cost.
                '';
            };
        };
    });

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
    mkHome = name: agent: { lib, pkgs, ... }: {
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

            # The stock renderer, or the mobile PWA when this agent asked for
            # it.  Everything else about the package is identical either way --
            # same venv, same skills, same gateway -- so the agent's state and
            # behaviour do not depend on which UI it serves.
            package = lib.mkIf agent.mobile.enable hermesMobile.package;

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
                # Pin the model id to "hermes-<name>" so that multiple agents
                # on the same host each expose a unique id through the model
                # gateway.  Without this every agent reports "hermes-agent" and
                # the gateway silently serves only one of them (the higher-
                # priority collision winner).  Clients send model="hermes-karl"
                # or model="hermes-joni"; the gateway strips no prefix because
                # the id is already unique.
                API_SERVER_MODEL_NAME = "hermes-${name}";
            } // lib.optionalAttrs agent.dashboard.enable {
                # The dashboard's auth gate (on for any non-loopback bind)
                # takes username/password from .env.  The username is not a
                # secret, so it is fixed here to the Unix user name; the
                # password and the cookie secret live in environmentFile.
                HERMES_DASHBOARD_BASIC_AUTH_USERNAME = name;
            };

            extraDependencyGroups = cfg.dependencyGroups;
            # `pkgs.systemd` is not decoration: the Kanban dispatcher spawns
            # each worker inside `systemd-run --user --scope` so the child
            # survives a gateway restart.  User units do NOT inherit the
            # system PATH, and upstream's processPath only contributes
            # hermes/bash/coreutils/git plus extraPackages -- so without
            # this, systemd-run is simply not found and EVERY card fails to
            # spawn, twice, then auto-blocks via the circuit breaker.
            #
            # The reported error is badly misleading ("systemd-run --user
            # --scope is unavailable (usually no reachable user D-Bus
            # session ...)", suggesting `loginctl enable-linger`) -- linger
            # and the bus are fine here; the binary is just absent from the
            # unit's PATH.  Verified on this host: cards sat in `blocked`
            # with spawn_failed x2 while `systemd-run --user --scope` ran
            # perfectly from an interactive shell as the same user.
            #
            # Fleet-wide rather than per-agent: any agent whose profiles
            # receive Kanban cards needs it, and an agent silently missing
            # it has a dead board with a misdiagnosing error message.
            extraPackages = agent.extraPackages
                ++ [ pkgs.systemd ]
                ++ lib.optional agent.googleWorkspace.enable googlePython;

            # Fleet-wide servers first, per-agent second.  `//` is a shallow
            # merge: a per-agent server with the same name replaces the
            # fleet-wide one outright, which is what you want when one person
            # needs the same server with different args.
            mcpServers = cfg.mcpServers // agent.mcpServers;

            # Rendered to config.yaml.  `${OPENAI_API_KEY}` is written
            # literally (note the backslash) and resolved by hermes from .env
            # at runtime, so no secret ever reaches the Nix store.
            #
            # Three layers, each deep-merged over the last: the module's
            # defaults, the fleet-wide `settings`, the agent's own.
            settings = lib.recursiveUpdate (lib.recursiveUpdate ({
                model = {
                    provider = "custom";
                    base_url = cfg.modelBaseUrl;
                    default = agent.model;
                    api_key = "\${OPENAI_API_KEY}";
                };
            } // lib.optionalAttrs cfg.doclingPdfHook.enable {
                # Fleet-wide, not per-agent: "every PDF goes through docling"
                # is a property of the host's document pipeline, so it is one
                # switch for everyone rather than a flag each agent can forget.
                #
                # pre_tool_call is the only hook that can rewrite arguments
                # before dispatch, which is what makes this an interception
                # rather than a suggestion -- read_file is handed a Markdown
                # path and never opens the PDF.  A skill cannot do this: it
                # would only advise the model, and advice is skipped.
                hooks.pre_tool_call = [{
                    matcher = "read_file";
                    command = doclingHookCommand;
                    timeout = cfg.doclingPdfHook.timeout + 10;
                    # A crashed or missing converter must not silently fall
                    # back to the text-layer extractor: that is the exact
                    # failure this hook exists to prevent, and it is invisible
                    # in the output.  Blocking makes the agent say so.
                    fail_closed = true;
                }];
            }) cfg.settings) agent.settings;

            # SOUL.md is only honoured from HERMES_HOME, not from the
            # workspace -- hence hermesHomeFiles and not `documents`.
            hermesHomeFiles = lib.optionalAttrs (agent.soul != null) {
                "SOUL.md" = agent.soul;
            } // lib.optionalAttrs cfg.doclingPdfHook.enable {
                # Pre-approves the hook so the gateway, which has no TTY to
                # prompt on, actually registers it.  Written declaratively
                # because a hook that is merely configured and never approved
                # is silently inactive -- the worst outcome here, since it
                # looks enabled in config.yaml.
                "shell-hooks-allowlist.json" = doclingAllowlist;
            } // mkProfileFiles agent;

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

        # Each declared sub-profile needs its OWN .env.  Hermes resolves a
        # profile's credentials from `<HERMES_HOME>/profiles/<name>/.env`
        # with NO fallback to the top-level `.env` (hermes_cli/profiles.py
        # seeds a placeholder .env per profile precisely so the root one is
        # never read) -- a profile without one simply has no credentials.
        # The upstream Home Manager module only ever renders ONE .env, at
        # the top level via `environmentFiles`, so sub-profiles would be
        # left without any and fail on their first model call.
        #
        # Every profile gets a copy of the SAME agenix secret the top-level
        # profile uses.  A plain `install`, not upstream's envScript, because
        # that script exists to fold in the top-level's non-secret
        # dashboard/API-server vars (HERMES_DASHBOARD_BASIC_AUTH_USERNAME,
        # API_SERVER_*), which are meaningless for a sub-profile -- only the
        # agent's one gateway/backend binds ports.  If a profile ever needs
        # narrower credentials than its siblings (its own GITHUB_TOKEN, say),
        # give it a real per-profile agenix secret and point this at that
        # path for that profile only.
        #
        # entryAfter "hermesAgentSetup": that upstream activation entry is
        # what creates profiles/<name>/ in the first place (installDocuments
        # over hermesHomeFiles).  `install -D` would make the directory
        # itself, so this ordering is for legibility, not necessity.
        home.activation.hermesProfileEnv = lib.hm.dag.entryAfter [ "hermesAgentSetup" ] (
            lib.concatMapStringsSep "\n" (pname: ''
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 0600 \
                    ${lib.escapeShellArg agent.environmentFile} \
                    ${lib.escapeShellArg "/home/${name}/.hermes/profiles/${pname}/.env"}
            '') (lib.attrNames agent.profiles)
        );
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
                default =
                    if cfg.secretsBackend == "agenix"
                    then config.age.secrets."hermes-${name}".path
                    else "${cfg.secretsDir}/${name}.env";
                defaultText = lib.literalExpression ''
                    if secretsBackend == "agenix"
                    then config.age.secrets."hermes-<name>".path
                    else "''${config.services.hermes-agents.secretsDir}/<name>.env"
                '';
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
                    defaults and the fleet-wide `services.hermes-agents.settings`
                    (so `model.default` here overrides `model`).
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

            googleWorkspace = {
                enable = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = ''
                        Give this agent the Google Workspace toolchain: Gmail,
                        Calendar, Drive, Docs, Sheets and Contacts over OAuth,
                        via the `google-workspace` skill.

                        Adds a python3 carrying google-auth,
                        google-auth-oauthlib and google-api-python-client to
                        the agent's PATH (the skill imports them; NixOS cannot
                        pip install into a read-only store).

                        Credentials are NOT deployed by this option, and two
                        different things are involved:

                          * the OAuth *client secret* (downloaded from Google
                            Cloud Console).  Set `clientSecretFile`, or leave
                            it at its default, which follows `secretsBackend`
                            exactly like `environmentFile` does:
                              agenix  -> /run/agenix/google-<name>
                              envFile -> ''${secretsDir}/google-<name>.json

                          * the OAuth *token*, minted by the consent flow ON
                            the machine and written to
                            ~/.hermes/google_token.json (0600).  It contains a
                            long-lived refresh token, is per-account, and
                            refreshes itself -- no deployment system can
                            pre-seed it.  Expect one interactive setup per
                            agent:
                              sudo -iu <name> python \
                                ~/.hermes/skills/productivity/google-workspace/scripts/setup.py \
                                --client-secret <clientSecretFile>
                    '';
                };

                clientSecretFile = lib.mkOption {
                    type = lib.types.str;
                    default = googleClientSecretPath name;
                    defaultText = lib.literalExpression ''
                        if secretsBackend == "agenix"
                        then config.age.secrets."google-<name>".path
                        else "''${secretsDir}/google-<name>.json"
                    '';
                    description = ''
                        Path to this agent's Google OAuth client secret JSON.
                        Passed to the skill's setup script; never read by Nix,
                        so the file only has to exist when you run the OAuth
                        flow -- not at build time.
                    '';
                };
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

            mobile.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                    Serve the mobile PWA renderer (sremes/hermes-mobile)
                    instead of the stock dashboard UI on this agent's
                    dashboard port.

                    The stock renderer is the desktop layout: it assumes a
                    mouse and a wide window, and on a phone the on-screen
                    keyboard covers the composer.  The PWA is the same
                    renderer with a mobile layout and
                    `interactive-widget=resizes-content`, so the composer
                    moves with the keyboard instead of hiding behind it, and
                    it installs to the home screen from the browser's
                    "Add to Home screen".

                    This changes only which files the dashboard serves.  The
                    gateway, state.db, skills and memory are untouched, and
                    the PWA is a thin client of the same backend -- it ships
                    no agent of its own.  Off leaves the agent byte-identical
                    to an unpatched build, so flipping it back and rebuilding
                    is a complete rollback.
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
                    http://homeserver:<port>/v1 with model "hermes-<name>".

                    The model id is fixed to "hermes-<name>" (e.g.
                    "hermes-karl") via API_SERVER_MODEL_NAME so that multiple
                    agents can coexist in the model gateway without colliding.

                    When services.model-gateway is enabled the API server is
                    automatically registered as a gateway endpoint, so clients
                    can reach every agent through the single gateway port
                    instead of each agent's individual port.

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

            profiles = lib.mkOption {
                type = lib.types.attrsOf profileSubmodule;
                default = {};
                example = lib.literalExpression ''
                    {
                      inherit (profiles) orchestrator researcher;
                      coder = profiles.coder // { model = "Qwen2.5-Coder-7B"; };
                    }
                '';
                description = ''
                    Declarative Hermes sub-profiles for this agent, i.e.
                    `~/.hermes/profiles/<name>/` for a `hermes -p <name> ...`
                    invocation, a Desktop profile switch, or a Kanban
                    dispatcher worker assigned to that profile name.  Each
                    entry renders that profile's config.yaml (model,
                    toolsets, mcp_servers), its .env, and -- if set --
                    SOUL.md and profile.yaml.

                    In this repo the values normally come from the presets in
                    `hermes/profiles/`, grafted by name via `hermes/lib.nix`;
                    merge over one with `//` to tweak it for a single agent.

                    All of an agent's profiles share that agent's ONE gateway
                    process, HERMES_HOME and `~/.hermes/kanban.db` -- which
                    is what lets a `kanban`-toolset profile route cards to
                    its siblings.  It does NOT span Unix accounts: each
                    agent has its own board, matching this module's
                    per-user isolation.

                    NOTE per-profile cron requires
                    `settings.gateway.multiplex_profiles = true` (set
                    fleet-wide in hermes/fleet.nix).  Cron stores are
                    per-profile, and a non-multiplexing gateway ticks only
                    the top-level profile's store -- a sub-profile's jobs
                    would sit unfired with no error.

                    Skills are deliberately NOT declared here.  A profile's
                    `skills/` directory is seeded by Hermes on first use and
                    never touched by this module, so `nixos-rebuild` cannot
                    wipe hand- or agent-authored skills.  Manage them the
                    normal way (`hermes -p <name>` + skill_manage, or the
                    Desktop app), and share them across profiles with
                    `settings.skills.external_dirs` if wanted.
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

        secretsBackend = lib.mkOption {
            type = lib.types.enum [ "envFile" "agenix" ];
            default = "envFile";
            description = ''
                Where each agent's secrets come from.

                "envFile" (default) reads ${"secretsDir"}/<name>.env, created
                out of band by an administrator.  Simple, but plaintext on
                disk, invisible to the repo, and lost on a rebuild from
                scratch.

                "agenix" instead declares one age-encrypted secret per agent
                automatically -- adding an agent to `agents` creates its
                secret with no further wiring.  Each is decrypted at
                activation to /run/agenix/hermes-<name> (tmpfs), owned by that
                agent and mode 0400, and `environmentFile` defaults to that
                path.

                With "agenix" you must also, per agent <name>:
                  * add a rule to secrets/secrets.nix for "hermes-<name>.age"
                  * create it with `agenix -e secrets/hermes-<name>.age`
                See secrets/README.md.
            '';
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

        mobile = {
            rev = lib.mkOption {
                type = lib.types.str;
                default = "864514961e57a83ebe4684a480279be35534e8f1";
                description = ''
                    sremes/hermes-mobile commit the PWA is built from, for
                    agents with `mobile.enable`.

                    Pinned to a commit, never a branch: this is a fork of the
                    Hermes Desktop renderer, so it speaks the /api contract of
                    a particular hermes-agent version.  Bump it in the same PR
                    that bumps the hermes-agent flake input, or a newer
                    backend can end up paired with an older renderer.
                '';
            };

            hash = lib.mkOption {
                type = lib.types.str;
                default = "sha256-DVXku5yg5iK/FtXQ0k3bRFy1NpZxR6cb1H0wEzBrXLw=";
                description = ''
                    SRI hash of the source tree for `mobile.rev`.  Obtain with
                    `nix flake prefetch --json github:sremes/hermes-mobile/<rev>`.
                '';
            };
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

        settings = lib.mkOption {
            type = lib.types.attrs;
            default = {};
            example = lib.literalExpression ''
                {
                  stt.provider = "openai";
                  stt.openai.base_url = "http://192.168.42.2:8110/v1";
                }
            '';
            description = ''
                config.yaml keys every agent gets, deep-merged over the
                module's defaults and under each agent's own `settings`, so
                an agent can still override any leaf.  For things that are
                the same for everyone -- a shared speech server, memory
                defaults -- rather than repeating them per agent.
            '';
        };

        doclingPdfHook = {
            enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                    Force every PDF that any agent's `read_file` touches
                    through docling-serve, instead of Hermes' built-in
                    extractor.

                    Fleet-wide on purpose, and deliberately not a per-agent
                    option: it describes how this HOST converts documents, the
                    same way `modelBaseUrl` describes where inference happens.
                    Per-agent would mean one agent silently reading worse text
                    than another from the same file.

                    Mechanism: a `pre_tool_call` shell hook matched on
                    `read_file`.  The hook converts the PDF, caches the
                    Markdown under ~/.hermes/cache/docling/<sha256>.md, and
                    rewrites the tool's `path` argument to point at it, so
                    read_file is never handed the PDF.  This covers uploads and
                    agent-downloaded files alike, because both are just files
                    on disk by the time read_file runs.

                    Why not a skill: a skill is advice to the model, which it
                    can skip, compact away, or apply inconsistently across
                    agents.  This is in the dispatch path.  Keep a skill for
                    the judgement calls (chunking, table handling); use this
                    for the guarantee.

                    Not covered: PDF *URLs* handed to web_extract, which never
                    become local files -- a separate path, and not intercepted
                    here.

                    Requires a reachable docling at `url`.  It fails closed:
                    if docling is down the read is blocked with an explanatory
                    message rather than silently falling back to the
                    text-layer extractor, which would hand the agent worse
                    text with no indication the good path was skipped.
                '';
            };

            url = lib.mkOption {
                type = lib.types.str;
                default =
                    if options.services ? docling
                    then "http://127.0.0.1:${toString config.services.docling.port}"
                    else "http://127.0.0.1:3070";
                defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.services.docling.port}"'';
                description = ''
                    docling-serve base URL, no trailing slash.  Derived from
                    services.docling.port when this host runs one, so the port
                    is declared once; the `options ?` guard keeps the module
                    evaluable on a host that does not import docling.nix and
                    points at a remote instance instead.
                '';
            };

            timeout = lib.mkOption {
                type = lib.types.int;
                default = 120;
                description = ''
                    Seconds the hook waits for a conversion.  The hook's own
                    Hermes-side timeout is this plus a 10s margin, so curl
                    gives up first and the agent gets docling's error rather
                    than an opaque "hook timed out".

                    120 suits GPU conversion of ordinary documents.  A
                    scanned hundred-page scan on CPU can exceed it; raise it
                    rather than letting the tool call block.
                '';
            };
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
            {
                # The hook fails closed, so pointing it at nothing would turn
                # every PDF read into a blocked tool call.  Catch the typo at
                # eval time instead.
                assertion = !cfg.doclingPdfHook.enable
                    || (cfg.doclingPdfHook.url != "" && !lib.hasSuffix "/" cfg.doclingPdfHook.url);
                message = "services.hermes-agents.doclingPdfHook.url must be non-empty and have no trailing slash.";
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

        # Auto-register each agent's API server as a model-gateway endpoint.
        #
        # The `options ?` guard keeps this module evaluable on hosts that do
        # not import model-gateway.nix -- the endpoints option is declared
        # unconditionally in that module, but the guard avoids an "undefined
        # option" error when the module is absent.
        #
        # Each agent gets its own named endpoint ("hermes-<name>") and the
        # gateway probes /v1/models to discover the model id, which Hermes
        # reports as "hermes-<name>" (see API_SERVER_MODEL_NAME above).  No
        # prefix is needed: the ids are already unique.
        #
        # Auth is enforced by Hermes itself (API_SERVER_KEY bearer check), not
        # the gateway -- the gateway forwards the Authorization header
        # unchanged, exactly as it does for every other request.  Local models
        # that ignore the header are unaffected.
        services.model-gateway.endpoints = lib.mkIf (options.services ? model-gateway) (
            lib.mapAttrs' (name: agent:
                lib.nameValuePair "hermes-${name}" {
                    url = "http://127.0.0.1:${toString agent.apiServerPort}";
                    discovery = "probe";
                    # Lower priority than local llama.cpp servers (100) so a
                    # name collision (unlikely -- Hermes uses "hermes-<name>")
                    # is won by the inference server, not the agent.
                    priority = 50;
                }
            ) (lib.filterAttrs (_: a: a.apiServerPort != null) cfg.agents)
        );

        # One age secret per agent, derived from `agents` exactly like
        # users.users above -- so adding an agent creates its secret with no
        # further wiring.  Decrypted at activation to /run/agenix/hermes-<name>
        # (tmpfs), owned by that agent, 0400: nobody else can read it, not even
        # the other agents.
        #
        # Agents with googleWorkspace.enable also get google-<name>, holding
        # their OAuth *client secret* JSON.  (The OAuth token is minted on the
        # machine by the consent flow and lives in ~/.hermes -- not here.)
        #
        # The .age files must exist in secrets/ and have rules in
        # secrets/secrets.nix; see secrets/README.md.
        age.secrets = lib.mkIf (cfg.secretsBackend == "agenix") (
            (lib.mapAttrs' (name: _: lib.nameValuePair "hermes-${name}" {
                file = ../../../secrets/hermes-${name}.age;
                owner = name;
                group = name;
                mode = "0400";
            }) cfg.agents)
            //
            (lib.mapAttrs' (name: _: lib.nameValuePair "google-${name}" {
                file = ../../../secrets/google-${name}.age;
                owner = name;
                group = name;
                mode = "0400";
            }) (lib.filterAttrs (_: a: a.googleWorkspace.enable) cfg.agents))
        );
    };
}
