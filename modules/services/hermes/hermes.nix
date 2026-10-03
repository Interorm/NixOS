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
    #
    # ALSO the interpreter for this module's own Google wrappers (see
    # googleFor below), deliberately: the auth CLI and the vendored
    # google_api.py must never run under different interpreters.  The vendored
    # skill's setup.py pins exact versions and calls `pip install` when they do
    # not match, which cannot work against a read-only store -- so the fleet
    # pins ONE interpreter here and everything Google-shaped uses it.
    googlePython = pkgs.python3.withPackages (ps: with ps; [
        google-auth
        google-auth-oauthlib
        google-api-python-client
    ]);

    # Where an agent's Google OAuth *client secret* comes from.  Mirrors
    # environmentFile: agenix when that backend is on, a plain path otherwise.
    #
    # NOTE this is the client secret (downloaded from Cloud Console), not the
    # OAuth token.  The two have opposite properties:
    #
    #   client secret  fleet-level app credential, identical for every agent,
    #                  weakly secret (a desktop/"installed" client's secret is
    #                  not a real secret -- PKCE is what protects the flow),
    #                  and therefore REPRODUCIBLE: one agenix'd ciphertext in
    #                  the repo, fanned out per agent at 0400.
    #   OAuth token    per ACCOUNT, holds a refresh token (the genuinely
    #                  dangerous half), minted by an interactive consent on the
    #                  machine, and therefore NOT reproducible by any
    #                  deployment system.  Lives in the agent's home at
    #                  ~/.hermes/google/<account>/google_token.json, 0600.
    #
    # The path is per-agent (/run/agenix/google-<name>) even though the
    # ciphertext is shared, so each agent gets its own 0400 decryption and no
    # agent can read another's -- see the age.secrets fan-out at the bottom of
    # this file.
    googleClientSecretPath = name:
        if cfg.secretsBackend == "agenix"
        then config.age.secrets."google-${name}".path
        else "${cfg.secretsDir}/google-${name}.json";

    # The capability vocabulary and its resolution, as plain data: no pkgs, no
    # config.  Imported here so the option TYPE for
    # `google.accounts.<n>.capabilities` is `enum <the valid names>` and a typo
    # is an eval error naming the valid set, produced by the module system
    # rather than by a hand-written assertion.
    googleLib = import ../../../hermes/google { inherit lib; };

    # The generated per-agent Google CLIs + manifest + skill store path, or
    # null for an agent that declares no account.
    #
    # Lazy on purpose: an agent with no Google accounts never forces this, so
    # googlePython and the wrappers stay out of that host's closure entirely.
    #
    # `hermesHome` must match where this module actually puts the agent's
    # Hermes home (see the activation entries below) -- the wrappers derive
    # every token path from it, and google_api.py derives its token path from
    # HERMES_HOME, so a mismatch would silently point the CLI at a token that
    # is never written.
    googleFor = name: agent:
        if agent.google.accounts == { } then null
        else import ../../../hermes/google/wrappers.nix {
            inherit pkgs lib googlePython;
            agent = name;
            accounts = agent.google.accounts;
            clientSecretFile = agent.google.clientSecretFile;
            hermesHome = "/home/${name}/.hermes";
        };

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

    # Remove mcp_servers entries the Nix config no longer declares.
    #
    # WHY THIS IS NEEDED AT ALL: an agent's top-level config.yaml is written
    # by upstream's merge script, which is `deep_merge(existing, nix)` --
    # Nix keys win, but keys only present ON DISK survive untouched.  That
    # is right for Hermes' own runtime bookkeeping (config_version, dashboard
    # state) and wrong for a declarative set: dropping a server from
    # `mcpServers` in Nix leaves it in config.yaml forever, so it keeps
    # loading and keeps costing prefill on every request.
    #
    # Observed: moving the fleet-wide MCP set to {} and scoping servers per
    # profile left every agent still carrying all the old fleet servers.
    # sabine, who should have exactly one (home-assistant), still had the
    # full set.  Sub-profiles were unaffected -- their config.yaml goes
    # through installDocuments' `install -D`, a full overwrite, so a removed
    # server really disappears there.  That asymmetry is the tell.
    #
    # Deliberately surgical: ONLY mcp_servers, and only keys absent from the
    # declared set.  A broad "replace the whole file" would also delete the
    # runtime keys the merge script exists to preserve.  Removing the
    # mcp_servers key entirely when nothing is declared keeps a stale block
    # from lingering as an empty-but-present map.
    pruneMcpScript = pkgs.writers.writePython3 "hermes-prune-mcp"
        { libraries = [ pkgs.python3Packages.pyyaml ]; flakeIgnore = [ "E501" ]; }
        ''
        import sys

        import yaml

        config_path, *declared = sys.argv[1:]

        try:
            with open(config_path) as fh:
                cfg = yaml.safe_load(fh) or {}
        except FileNotFoundError:
            sys.exit(0)

        servers = cfg.get("mcp_servers")
        if not isinstance(servers, dict):
            sys.exit(0)

        stale = [k for k in servers if k not in declared]
        if not stale:
            sys.exit(0)

        for key in stale:
            del servers[key]
        if servers:
            cfg["mcp_servers"] = servers
        else:
            cfg.pop("mcp_servers", None)

        with open(config_path, "w") as fh:
            yaml.dump(cfg, fh, default_flow_style=False, sort_keys=False)

        print("hermes-agents: pruned undeclared mcp_servers: " + ", ".join(sorted(stale)))
        '';

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
    mkHome = name: agent: { lib, pkgs, ... }: let
        # This agent's generated Google CLIs, or null when it declares no
        # account.  Bound once here so the four consumers below (extraPackages,
        # settings.skills.external_dirs, the manifest activation entry, and the
        # token-dir activation entry) cannot drift apart or disagree about the
        # store paths.
        gapi = googleFor name agent;
    in {
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
                # Google: the interpreter carrying the API client libraries,
                # plus one generated CLI per account (hermes-google-<account>)
                # and the three shared ones (auth / status / gmail).  Derived
                # from `google.accounts`, so declaring an account puts its
                # command on the agent's PATH with no second edit -- and an
                # agent with no accounts gets none of this in its closure.
                ++ lib.optionals (gapi != null) ([ googlePython ] ++ gapi.packages);

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
            } // lib.optionalAttrs (gapi != null) {
                # The repo-shipped google-oauth skill, as a READ-ONLY STORE
                # PATH.  external_dirs is the sanctioned hatch: this module
                # deliberately does not manage ~/.hermes/skills/ (see the
                # `profiles` option's description) so a rebuild cannot wipe
                # hand- or agent-authored skills, and copying a skill in there
                # would do exactly that.  A store path instead means the skill
                # is versioned with the flake, immutable at runtime, and
                # re-derived on every rebuild.
                skills.external_dirs = [ "${gapi.skillsDir}" ];
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
        # entryAfter "hermesAgentSetup": that upstream activation entry
        # installs hermesHomeFiles (including this profile's config.yaml,
        # SOUL.md and profile.yaml) and sets up the top-level home.
        home.activation.hermesProfileEnv = lib.hm.dag.entryAfter [ "hermesAgentSetup" ] (
            lib.concatMapStringsSep "\n" (pname: ''
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 0600 \
                    ${lib.escapeShellArg agent.environmentFile} \
                    ${lib.escapeShellArg "/home/${name}/.hermes/profiles/${pname}/.env"}
            '') (lib.attrNames agent.profiles)
        );

        # Real profile creation, before the declared files are installed
        # over the seeded defaults.  See mkProfileCreateScript for the full
        # rationale.  entryBefore "hermesAgentSetup" AND after
        # "writeBoundary"/"linkGeneration" is inherited from that entry's own
        # ordering, so the agenix secret is already decrypted by this point.
        home.activation.hermesProfileCreate =
            lib.mkIf (agent.profiles != {})
                (lib.hm.dag.entryBefore [ "hermesAgentSetup" ]
                    (mkProfileCreateScript name agent));

        # ~/.hermes/google/accounts.json -- the static manifest behind the CLI.
        #
        # `install -D -m 0600`, ordered exactly like hermesProfileEnv above:
        # entryAfter "hermesAgentSetup" guarantees the Hermes home exists and
        # the agenix secret is already decrypted.  A full overwrite, not a
        # merge, so the file is EXACT after every rebuild -- removing an account
        # from Nix removes it here, which a deep-merge (the trap config.yaml
        # falls into, see pruneMcpScript) would not do.
        #
        # install -D creates ~/.hermes/google/ as a side effect, which is also
        # the parent of every per-account token directory.
        #
        # The agent's primary interface is the CLI (`hermes-google-status`),
        # which reads LIVE token state; this file is the static policy data
        # behind it, and it is what a human or a script can diff against the
        # Nix source. Contains PATHS only, never a secret.
        home.activation.hermesGoogleManifest = lib.mkIf (gapi != null) (
            lib.hm.dag.entryAfter [ "hermesAgentSetup" ] ''
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 0600 \
                    ${gapi.manifest} \
                    ${lib.escapeShellArg "/home/${name}/.hermes/google/accounts.json"}
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 0700 \
                    ${lib.escapeShellArg "/home/${name}/.hermes/google"}
            ''
        );

        # Drop mcp_servers this config no longer declares.  MUST run after
        # hermesAgentSetup, which is what writes (merges) config.yaml -- the
        # stale keys do not exist to prune until that has run.  See
        # pruneMcpScript for why the merge alone cannot do this.
        #
        # Only the agent's top-level config.yaml needs it: sub-profile
        # configs are installed with `install -D`, a full overwrite, so they
        # are already exact.
        home.activation.hermesPruneMcp = lib.hm.dag.entryAfter [ "hermesAgentSetup" ] ''
            $DRY_RUN_CMD ${pruneMcpScript} \
                ${lib.escapeShellArg "/home/${name}/.hermes/config.yaml"} \
                ${lib.escapeShellArgs (lib.attrNames (cfg.mcpServers // agent.mcpServers))}
        '';
    };

    # Create each declared sub-profile with Hermes' OWN `profile create`,
    # before any of this module's files are written into it.
    #
    # WHY SHELL OUT INSTEAD OF RENDERING THE DIRECTORY OURSELVES: a Hermes
    # profile is not "a directory with some files in it", it is a directory
    # plus an initialisation PROCEDURE, and reproducing that procedure in
    # Nix means reproducing it wrongly.  `hermes_cli/profiles.py ::
    # create_profile()` makes nine state dirs (_PROFILE_DIRS = memories
    # sessions skills skins logs plans workspace cron home), seeds the
    # bundled skill catalogue (~58 skills), creates state.db, writes
    # profile.yaml, and runs a config-schema migration so the profile is not
    # stamped v0.  An earlier version of this module rendered only the files
    # it knew about and each rebuild surfaced another missing piece:
    #   * no .env            -> profile had no credentials at all
    #   * no sessions/       -> every Kanban worker died at startup with
    #                           HomeInitializationError (managed mode makes
    #                           Hermes REFUSE to create its own state dirs:
    #                           config_home.py passes create=not managed)
    #   * no skills/         -> 0 skills vs 58 in a real profile
    #   * only 5 of the 9 _PROFILE_DIRS, missing skins/ plans/ workspace/
    #     and home/ (the per-profile $HOME for tool subprocesses)
    # Those are instances of ONE mistake, not four bugs, and the list would
    # keep growing every time upstream adds to the procedure.
    #
    # (Not in that list, because checking showed it is not ours: a fresh
    # profile reports "config version outdated v0 -> v42" in `hermes
    # doctor` whether it was made by this module or by `hermes profile
    # create` directly -- the schema migration only runs for CLONED
    # profiles.  Cosmetic, upstream's, and deliberately not worked around
    # here.)
    #
    # So: Hermes owns CREATION, Nix owns CONFIGURATION.  This runs
    # `profile create` only when the directory is absent, which makes it
    # idempotent and leaves a profile's accumulated state (sessions,
    # memories, agent-authored skills) untouched across rebuilds.  The
    # config.yaml/SOUL.md/profile.yaml this module declares are written
    # AFTERWARDS by the upstream activation, over the seeded defaults --
    # upstream's merge script deep-merges the Nix keys over what is on disk
    # (`deep_merge(existing, nix)`), so declared keys win while
    # Hermes-owned bookkeeping like config_version survives.
    #
    # --no-alias: the `~/.local/bin/<name>` wrapper is a convenience for
    # interactive shells and not needed for `-p` or Kanban routing; leaving
    # it out keeps activation from writing outside HERMES_HOME.
    # --description: what the Kanban decomposer routes on.  Passed here as
    # well as rendered into profile.yaml so a profile is routable from the
    # moment it exists, even before the first file install.
    #
    # Ordering: entryBefore hermesAgentSetup, because that entry installs
    # this profile's declared files and they must land on top of, not under,
    # the seeded defaults.
    #
    # Failure policy: a failed creation must NOT abort activation (that
    # would take the whole system generation down over one profile).  It
    # warns loudly instead; the profile is then missing and its Kanban cards
    # will not dispatch, which is visible on the board.
    mkProfileCreateScript = name: agent: let
        hermesBin = "${
            if agent.mobile.enable then hermesMobile.package else
            inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default
        }/bin/hermes";
        home = "/home/${name}/.hermes";
    in lib.concatMapStringsSep "\n" (pname: let
        p = agent.profiles.${pname};
        descArgs = lib.optionalString (p.description != null)
            "--description ${lib.escapeShellArg p.description}";
    in ''
        if [ ! -d ${lib.escapeShellArg "${home}/profiles/${pname}"} ]; then
          echo "hermes-agents: creating profile '${pname}' for ${name}"
          # HERMES_HOME pins the parent home so the new profile lands under
          # it rather than under whatever home the activation inherits.
          # HERMES_MANAGED is deliberately NOT unset: `profile create` has no
          # managed-mode gate (verified against hermes_cli/profiles.py), so
          # it works as-is and the marker keeps the rest of the CLI honest.
          $DRY_RUN_CMD env HERMES_HOME=${lib.escapeShellArg home} \
            ${hermesBin} profile create ${lib.escapeShellArg pname} \
            --no-alias ${descArgs} \
            || echo "hermes-agents: WARNING could not create profile '${pname}' for ${name}; its Kanban cards will not dispatch" >&2
        fi
    '') (lib.attrNames agent.profiles);

    agentSubmodule = lib.types.submodule ({ name, ... }@submoduleArgs: let
        # The agent's own name, bound before any nested submodule can shadow
        # `name` with its own entity name (google.accounts.<account> does
        # exactly that).  Without this, a per-account default that needs the
        # AGENT's name would silently get the ACCOUNT's.
        agentName = name;

        # This agent's OWN resolved config, reached through the @-pattern rather
        # than by adding `config` to the argument list.  Naming it `config` here
        # would SHADOW the file-level NixOS `config` that several defaults in
        # this submodule read inline (environmentFile reaches
        # `config.age.secrets."hermes-<name>".path`), turning them into silent
        # lookups against the wrong attrset.
        selfCfg = submoduleArgs.config;
    in {
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

            # ---------------------------------------------------------------
            # Google access: per-account, capability-based, declarative.
            #
            # Replaces the old boolean `googleWorkspace.enable`, which could
            # express exactly one thing -- "this agent gets ALL of Gmail,
            # Calendar, Drive, Docs, Sheets and Contacts, including send and
            # delete" -- and nothing narrower.  There was no way to say "read
            # and label my personal mail but never send as me", which is the
            # actual requirement.
            #
            # ENFORCEMENT NOTE, stated here because it governs how to read
            # everything below: Google validates every API call against the
            # scopes baked into the TOKEN minted at the consent screen, and
            # returns 403 insufficient_permission for anything outside them.
            # The token is the security boundary -- it holds even if the agent
            # is confused or has just read a prompt-injecting email.  This
            # option, the generated manifest and the shipped skill are
            # ADVISORY: they buy correct behaviour and comprehensible errors,
            # not safety.  In particular, shrinking `capabilities` here does
            # NOT shrink a token that was already minted; the account must
            # re-consent.  `hermes-google-status` prints declared and granted
            # side by side for exactly this reason.
            # ---------------------------------------------------------------
            google = {
                accounts = lib.mkOption {
                    default = { };
                    example = lib.literalExpression ''
                        {
                          agent.capabilities = [ "mail.full" "calendar.rw" ];
                          personal = {
                            address = "karl@example.com";
                            capabilities = [ "mail.read" "mail.labels" "mail.rules" ];
                            purpose = "Read-only triage of Karl's personal mail. Never send.";
                          };
                        }
                    '';
                    description = ''
                        Google accounts this agent may use, one attribute per
                        account.  The attribute name is the local handle: it
                        names the token directory
                        (`~/.hermes/google/<name>/`), the generated command
                        (`hermes-google-<name>`) and the `--account` selector.
                        It is NOT an email address -- see `address` for that.

                        Each declared account automatically gets its OAuth
                        scopes derived from `capabilities`, a per-account token
                        home, an entry in `~/.hermes/google/accounts.json`, and
                        its own generated wrapper on the agent's PATH.  Adding
                        an account here is the only edit required.

                        One interactive OAuth consent per account is needed
                        once, on the machine, via `hermes-google-auth <name>`.
                        That is a legitimate one-time bootstrap: it is NOT
                        repeated after a `nixos-rebuild`, because the token
                        lives in the agent's home rather than the store.
                    '';
                    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
                        options = {
                            capabilities = lib.mkOption {
                                # `enum` from the capability table, so a typo'd
                                # name fails at EVAL with the valid set printed
                                # by the type checker -- rather than resolving
                                # to a missing attribute later, or worse, to an
                                # empty scope list that only fails at the
                                # consent screen in a browser.
                                type = googleLib.capabilityType;
                                default = [ ];
                                example = [ "mail.read" "mail.labels" "mail.rules" ];
                                description = ''
                                    What this account may do, as capability
                                    names from `hermes/google/capabilities.nix`.
                                    Scopes are derived; never write a scope URL
                                    here or anywhere else.

                                    Valid names:
                                    ${lib.concatMapStringsSep "\n" (c: "  * ${c}") googleLib.capabilityNames}

                                    /!\ `mail.write` (and `mail.full`) ALSO
                                    GRANT SEND.  Gmail couples modify and send:
                                    the set of scopes permitting
                                    `messages.modify` but not `messages.send`
                                    is empty.  For auto-labeling without send,
                                    use `mail.rules` (a server-side Gmail
                                    filter) and accept that it applies to mail
                                    arriving from now on.
                                '';
                            };

                            address = lib.mkOption {
                                type = lib.types.nullOr lib.types.str;
                                default = null;
                                example = "hermes.agent.karl@gmail.com";
                                description = ''
                                    Which Google identity this handle refers
                                    to.  Printed by `hermes-google-auth` and
                                    `hermes-google-status` so the human picks
                                    the right account at the consent screen --
                                    the single easiest way to ruin a careful
                                    scope split is to sign in as whichever
                                    account the browser happened to be in.

                                    Advisory only: nothing can force Google to
                                    use it.  null means "not pinned", and the
                                    CLI says so loudly.
                                '';
                            };

                            purpose = lib.mkOption {
                                type = lib.types.str;
                                default = "";
                                example = "Read-only triage of Karl's personal mail. Never compose or send.";
                                description = ''
                                    Human prose THE AGENT READS, printed by
                                    `hermes-google-status` and carried in the
                                    manifest: what this account is for and what
                                    it must not be used for.

                                    This exists because `capabilities` says
                                    what an account CAN do and that is not the
                                    same as what it SHOULD do -- an account
                                    that technically carries `mail.write` can
                                    still be meant for reading only.  The
                                    shipped `google-oauth` skill instructs the
                                    agent to read this before choosing an
                                    account.

                                    Advisory, like everything outside the
                                    token.
                                '';
                            };

                            publishing = lib.mkOption {
                                type = lib.types.enum [ "testing" "production" ];
                                default = "testing";
                                description = ''
                                    Publishing status of the Google Cloud OAuth
                                    app this account consents through.  Not a
                                    setting -- a FACT about the Cloud Console,
                                    recorded here so the consequence is
                                    visible.

                                    "testing" (the default, and where this
                                    fleet's app currently is): Google issues
                                    refresh tokens that EXPIRE AFTER ~7 DAYS
                                    for users external to the app's own
                                    project.  The project's own account
                                    survives; anyone else's does not, and the
                                    symptom is an opaque auth failure roughly
                                    weekly.  `hermes-google-status` surfaces
                                    this caveat per account.

                                    "production" requires Google verification,
                                    because every Gmail scope is sensitive or
                                    restricted.

                                    Nix cannot fix this; it can only make it
                                    visible before it bites.
                                '';
                            };

                            project = lib.mkOption {
                                type = lib.types.nullOr lib.types.str;
                                default = null;
                                example = "hermes-personal-readonly";
                                description = ''
                                    Optional Google Cloud project this
                                    account's OAuth client belongs to, when it
                                    is NOT the fleet default.

                                    Why this exists: the scope list on the Data
                                    Access page is a PROJECT-level config
                                    shared by every OAuth client in that
                                    project.  A "read-only client" inside a
                                    project that also lists write scopes
                                    enforces nothing -- a client cannot have a
                                    narrower ceiling than its project.  The
                                    only hard, independent ceiling is a
                                    SEPARATE project (with its own client
                                    secret).

                                    Recorded for documentation today; a second
                                    project would also need a second
                                    `age.secrets` entry for its client secret.
                                '';
                            };

                            scopes = lib.mkOption {
                                type = lib.types.listOf lib.types.str;
                                readOnly = true;
                                default = googleLib.scopesFor config.capabilities;
                                defaultText = lib.literalExpression
                                    "derived from `capabilities` via hermes/google/capabilities.nix";
                                description = ''
                                    Read-only: the deduplicated, sorted OAuth
                                    scope URLs derived from `capabilities`.
                                    Exposed so a consumer (and a tier-2 eval)
                                    can assert on the resolved value rather
                                    than re-deriving it, which is how a
                                    "verification" ends up proving only that
                                    two copies of the same mistake agree.
                                '';
                            };

                            tokenPath = lib.mkOption {
                                type = lib.types.str;
                                readOnly = true;
                                default = "/home/${agentName}/.hermes/google/${name}/google_token.json";
                                defaultText = lib.literalExpression
                                    "\"/home/<agent>/.hermes/google/<account>/google_token.json\"";
                                description = ''
                                    Read-only: where this account's OAuth token
                                    lands, 0600, written by
                                    `hermes-google-auth`.

                                    The basename is fixed by the vendored
                                    google-workspace skill, which computes
                                    `HERMES_HOME / "google_token.json"`.  The
                                    per-account DIRECTORY is what makes it
                                    per-account: the wrappers export
                                    `HERMES_HOME=~/.hermes/google/<account>`
                                    and the vendored script needs no patch and
                                    has no `--account` flag.
                                '';
                            };
                        };
                    }));
                };

                clientSecretFile = lib.mkOption {
                    type = lib.types.str;
                    default = googleClientSecretPath agentName;
                    defaultText = lib.literalExpression ''
                        if secretsBackend == "agenix"
                        then config.age.secrets."google-<name>".path
                        else "''${secretsDir}/google-<name>.json"
                    '';
                    description = ''
                        Path to the OAuth *client secret* JSON used when
                        minting tokens for this agent's accounts.

                        FLEET-LEVEL, not personal: one app credential shared by
                        every agent and every account, from one
                        `secrets/google-client.age` fanned out to a per-agent
                        `/run/agenix/google-<name>` at 0400.  Enabling Google
                        for a new agent needs no new `.age` file and no new
                        recipient rule.

                        Read only at consent time, never by Nix, so the file
                        has to exist when someone runs `hermes-google-auth` --
                        not at build time.
                    '';
                };
            };

            # Deprecated alias for the whole of the above.  KEPT WORKING on
            # purpose: Karl merges and rebuilds incrementally, so a single
            # commit must not break a host that still sets the boolean.
            #
            # `mail.full calendar.rw drive.rw sheets.rw docs.rw contacts.ro`
            # is exactly the SCOPES list the vendored google-workspace
            # setup.py requests, so a migrated agent's EXISTING token stays
            # valid with no re-consent.
            googleWorkspace = {
                enable = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = ''
                        DEPRECATED -- use `google.accounts` instead.

                        `googleWorkspace.enable = true` is equivalent to:

                            google.accounts.agent = {
                              capabilities = [
                                "mail.full" "calendar.rw" "drive.rw"
                                "sheets.rw" "docs.rw" "contacts.ro"
                              ];
                            };

                        i.e. one account named `agent` with full access,
                        including SEND and TRASH on Gmail.  That scope list is
                        byte-identical to what the vendored google-workspace
                        skill's setup.py has always requested, so an existing
                        `~/.hermes/google_token.json` remains valid -- moving
                        it to `~/.hermes/google/agent/google_token.json`
                        preserves access with no re-consent.

                        The alias is emitted with `lib.mkDefault`, so declaring
                        `google.accounts.agent.capabilities` yourself REPLACES
                        it outright rather than merging into a surprising union
                        of both lists.  A `warnings` entry fires while the
                        boolean is in use.
                    '';
                };

                clientSecretFile = lib.mkOption {
                    type = lib.types.str;
                    default = googleClientSecretPath agentName;
                    defaultText = lib.literalExpression ''google.clientSecretFile'';
                    description = ''
                        DEPRECATED -- use `google.clientSecretFile`.  Kept so a
                        host that set it still evaluates; the value is not read
                        by anything.
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

        # --------------------------------------------------------------- #
        # Back-compat: the deprecated boolean, expressed as a definition of
        # the new option rather than as a second code path.
        #
        # Defining `google.accounts.agent` from inside the same submodule
        # that declares it is the ordinary direction (define one option by
        # reading a DIFFERENT one -- here `googleWorkspace.enable`), so it
        # does not recurse.  Every downstream consumer -- the wrappers, the
        # manifest, extraPackages, the age.secrets fan-out -- reads only
        # `google.accounts`, so there is exactly ONE code path and the
        # deprecated branch is tested by the same evals as the new one.
        #
        # `lib.mkDefault` (priority 1000) so a host that sets both the
        # boolean and an explicit `google.accounts.agent.capabilities` gets
        # its own list, not a union of the two -- a union would silently
        # re-add send to an account somebody was deliberately narrowing.
        # --------------------------------------------------------------- #
        config = lib.mkIf selfCfg.googleWorkspace.enable {
            google.accounts.agent = {
                capabilities = lib.mkDefault [
                    "mail.full"
                    "calendar.rw"
                    "drive.rw"
                    "sheets.rw"
                    "docs.rw"
                    "contacts.ro"
                ];
                purpose = lib.mkDefault ''
                    The agent's own Google mailbox and workspace (migrated from
                    the deprecated googleWorkspace.enable boolean).  Full
                    access: it can read, label, trash AND SEND mail as itself.
                    This is the agent's OWN identity, not a human's -- do not
                    use it to act as ${agentName}.
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

        # Deprecation notice for the boolean, emitted once per agent still
        # using it.  A `warnings` entry rather than an assertion on purpose:
        # the boolean must keep WORKING through an incremental migration, so
        # breaking the build would be exactly wrong.
        warnings = lib.mapAttrsToList (name: _:
            "services.hermes-agents.agents.${name}.googleWorkspace.enable is deprecated. "
            + "It now resolves to google.accounts.agent with full access "
            + "(mail.full calendar.rw drive.rw sheets.rw docs.rw contacts.ro) -- "
            + "note mail.full includes SEND. Replace it with an explicit "
            + "google.accounts block in hermes/users/${name}.nix; see "
            + "hermes/google/capabilities.nix for the vocabulary."
        ) (lib.filterAttrs (_: a: a.googleWorkspace.enable) cfg.agents);

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
        # Agents with at least one `google.accounts` entry also get
        # google-<name>, holding the OAuth *client secret* JSON.  (The OAuth
        # token is minted on the machine by the consent flow and lives in
        # ~/.hermes/google/<account>/ -- not here.)
        #
        # ONE CIPHERTEXT, FANNED OUT PER AGENT.  Several age.secrets entries
        # may legitimately share a `file`: agenix decrypts it once per entry,
        # so secrets/google-client.age becomes
        #
        #   /run/agenix/google-karl   owner karl  0400
        #   /run/agenix/google-nana   owner nana  0400
        #   ...
        #
        # That keeps strict per-agent 0400 isolation (no agent can read
        # another's copy) while the repo holds a single file with a single
        # recipient rule.  Enabling Google for a new agent therefore needs NO
        # new .age file and NO new rule in secrets/secrets.nix.
        #
        # Deliberately NOT a shared group on one file: a group would widen who
        # can read the plaintext and would add a group to the system's
        # vocabulary for no gain -- the fan-out costs nothing but a decrypt.
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
                file = ../../../secrets/google-client.age;
                owner = name;
                group = name;
                mode = "0400";
            }) (lib.filterAttrs (_: a: a.google.accounts != { }) cfg.agents))
        );
    };
}
