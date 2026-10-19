{
    config, options, lib, pkgs, inputs,
    ...
}: let
    cfg = config.services.hermes-agents;

    # Google API client
    googlePython = pkgs.python3.withPackages (ps: with ps; [
        google-auth
        google-auth-oauthlib
        google-api-python-client
    ]);
    googleLib = import ../google { inherit lib; };

    googleFor = name: agent:
        if agent.google.accounts == { } then null
        else import ../google/wrappers.nix {
            inherit pkgs lib googlePython;
            agent = name;
            accounts = agent.google.accounts;
            clientSecretFile = agent.google.clientSecretFile;
            hermesHome = "/home/${name}/.hermes";
        };


    skillsReg = import ../lib.nix { inherit pkgs config lib; };

    skillEntry = name:
        if skillsReg.skills ? ${name} then [ skillsReg.skills.${name} ]
        else if skillsReg.skillPacks ? ${name} then skillsReg.skillPacks.${name}
        else throw "hermes-agents: unknown skill or pack '${name}' (skills: ${lib.concatStringsSep ", " (lib.attrNames skillsReg.skills)}; packs: ${lib.concatStringsSep ", " (lib.attrNames skillsReg.skillPacks)})";

    skillDirs = names: lib.unique (map toString (lib.concatMap skillEntry names));


    # The PDF -> docling hook, with its URL and timeout baked in. 
    doclingHook = pkgs.writeShellApplication {
        name = "hermes-docling-pdf-hook";
        runtimeInputs = with pkgs; [ jq curl coreutils ];
        text = ''
            export DOCLING_URL=${lib.escapeShellArg cfg.docling.url}
            export DOCLING_TIMEOUT=${toString cfg.docling.timeout}
        '' + builtins.readFile ./docling/docling-pdf-hook.sh;
    };

    doclingHookCommand = "${doclingHook}/bin/hermes-docling-pdf-hook";
    doclingAllowlist = builtins.toJSON {
        approvals = [
            { event = "pre_tool_call"; command = doclingHookCommand; }
        ];
    };


    # Remove mcp_servers entries the Nix config no longer declares.
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


    hermesMobile = import ./hermes-mobile.nix {
        inherit lib pkgs;
        hermesUpstream = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
        inherit (cfg.mobile) rev hash;
    };


    stripMcpMeta = lib.mapAttrs (_: srv: removeAttrs srv [ "meta" ]);

    # This essentially just pulls all data from the MCP
    mkProfileMcpServerEntry = srv:
        lib.optionalAttrs (srv ? command) { inherit (srv) command; args = srv.args or []; }
        // lib.optionalAttrs (srv ? env) { inherit (srv) env; }
        // lib.optionalAttrs (srv ? url) { inherit (srv) url; }
        // lib.optionalAttrs (srv ? headers) { inherit (srv) headers; }
        // { enabled = srv.enabled or true; };

    # One profile's config.yaml
    mkProfileConfig = agent: pname: p: let
        mergedMcp = cfg.mcpServers // p.mcpServers;
        profileSkillDirs = skillDirs (agent.skills ++ p.skills);
    in builtins.toJSON (lib.recursiveUpdate (lib.recursiveUpdate ({
        model = {
            provider = "custom";
            base_url = cfg.modelBaseUrl;
            default = if p.model != null then p.model else agent.model;
            api_key = "\${OPENAI_API_KEY}";
        };
        toolsets = p.toolsets;
        mcp_servers = lib.mapAttrs (_: mkProfileMcpServerEntry) mergedMcp;
    } // lib.optionalAttrs (profileSkillDirs != [ ]) {
        skills.external_dirs = profileSkillDirs;
    }) cfg.settings) p.settings);

    mkProfileFiles = agent: lib.foldl' (acc: pname: let
        p = agent.profiles.${pname};
        base = "profiles/${pname}";
    in acc
        // { "${base}/config.yaml" = mkProfileConfig agent pname p; }
        // lib.optionalAttrs (p.soul != null) { "${base}/SOUL.md" = p.soul; }
        // lib.optionalAttrs (p.description != null) {
            # What `hermes profile describe <name> --text ...` would write, required for Kanban
            "${base}/profile.yaml" = builtins.toJSON { description = p.description; };
        }
    ) {} (lib.attrNames agent.profiles);

    # Create each declared sub-profile with Hermes' OWN `profile create`,
    # before any of this module's files are written into it.
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
          $DRY_RUN_CMD env HERMES_HOME=${lib.escapeShellArg home} \
            ${hermesBin} profile create ${lib.escapeShellArg pname} \
            --no-alias ${descArgs} \
            || echo "hermes-agents: WARNING could not create profile '${pname}' for ${name}; its Kanban cards will not dispatch" >&2
        fi
    '') (lib.attrNames agent.profiles);

    # Individual Profile option set
    profileSubmodule = lib.types.submodule ({ name, ... }: {
        options = {
            model = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                defaultText = lib.literalExpression "the parent agent's model";
                description = "Default model for this profile. null inherits the parent agent's model.";
            };

            soul = lib.mkOption {
                type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
                default = null;
                description = "Soul for that agent. Required";
            };

            description = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "Web research, document analysis, fact-checking.";
                description = "Short description detailing what the profile is used for. Read by Kanban";
            };

            toolsets = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ "hermes-cli" ];
                example = [ "kanban" ];
                description = "Set avaible tools for the profile. Kanban is needed for delegation, hermes-cli for basic terminal access";
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
                description = "Additional config";
            };

            mcpServers = lib.mkOption {
                type = lib.types.attrsOf lib.types.attrs;
                default = {};
                description = "Full set of all MCP servers avaible to the model";
            };

            skills = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Curated skills from services/hermes/skills/, added via settings.skills.external_dirs.";
            };
        };
    });


    # Create home for one agent
    mkHome = name: agent: { lib, pkgs, ... }: let
        gapi = googleFor name agent;
        googleDirs = lib.optional (gapi != null) "${gapi.skillsDir}";
        curated = skillDirs agent.skills;
        allSkillDirs = googleDirs ++ curated;
    in {
        imports = [ inputs.hermes-agent.homeManagerModules.default ];

        home.username = name;
        home.homeDirectory = "/home/${name}";
        home.stateVersion = config.system.stateVersion;

        programs.bash.enable = true;

        programs.hermes-agent.enable = true;
        services.hermes-agent = {
            enable = true;
            gateway.enable = true;

            package = lib.mkIf agent.mobile.enable hermesMobile.package;

            environmentFiles = [ agent.environmentFile ];
            environment = lib.optionalAttrs (agent.apiServerPort != null) {
                API_SERVER_ENABLED = "true";
                API_SERVER_PORT = toString agent.apiServerPort;
                API_SERVER_HOST = "0.0.0.0";
                API_SERVER_MODEL_NAME = "hermes-${name}";
            } // lib.optionalAttrs agent.dashboard.enable {
                HERMES_DASHBOARD_BASIC_AUTH_USERNAME = name;
            };

            extraDependencyGroups = cfg.dependencyGroups;

            extraPackages = agent.extraPackages
                ++ cfg.extraPackages
                ++ [ pkgs.systemd ]
                # Add googlePython and all wrappers if enabled
                ++ lib.optionals (gapi != null) ([ googlePython ] ++ gapi.packages);

            mcpServers = stripMcpMeta (cfg.mcpServers // agent.mcpServers);

            settings = lib.recursiveUpdate (lib.recursiveUpdate ({
                model = {
                    provider = "custom";
                    base_url = cfg.modelBaseUrl;
                    default = agent.model;
                    api_key = "\${OPENAI_API_KEY}";
                };
            } // {
                skills.external_dirs = allSkillDirs;
            } // lib.optionalAttrs cfg.docling.enable {
                hooks.pre_tool_call = [{
                    matcher = "read_file";
                    command = doclingHookCommand;
                    timeout = cfg.docling.timeout + 10;
                    fail_closed = true;
                }];
            }) cfg.settings) agent.settings;

            hermesHomeFiles = lib.optionalAttrs (agent.soul != null) {
                "SOUL.md" = agent.soul;
            } // lib.optionalAttrs cfg.docling.enable {
                "shell-hooks-allowlist.json" = doclingAllowlist;
            } // mkProfileFiles agent;


            backend = lib.mkIf agent.dashboard.enable {
                mode = "dashboard";
                port = agent.dashboard.port;
                host = lib.mkIf (cfg.dashboard.host != null) cfg.dashboard.host;
                sessionTokenFile = agent.dashboard.sessionTokenFile;

                waitFor = lib.mkIf (cfg.dashboard.interface != null) "interface";
                interfaceName = cfg.dashboard.interface;
            };
        };

        # Each declared sub-profile needs its OWN .env.  
        home.activation.hermesProfileEnv = lib.hm.dag.entryAfter [ "hermesAgentSetup" ] (
            lib.concatMapStringsSep "\n" (pname: ''
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 0600 \
                    ${lib.escapeShellArg agent.environmentFile} \
                    ${lib.escapeShellArg "/home/${name}/.hermes/profiles/${pname}/.env"}
            '') (lib.attrNames agent.profiles)
        );

        # Create agent profiles via standard command
        home.activation.hermesProfileCreate =
            lib.mkIf (agent.profiles != {})
                (lib.hm.dag.entryBefore [ "hermesAgentSetup" ]
                    (mkProfileCreateScript name agent));

        # Install manifest.json for google access
        home.activation.hermesGoogleManifest = lib.mkIf (gapi != null) (
            lib.hm.dag.entryAfter [ "hermesAgentSetup" ] ''
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 0600 \
                    ${gapi.manifest} \
                    ${lib.escapeShellArg "/home/${name}/.hermes/google/accounts.json"}
                $DRY_RUN_CMD ${pkgs.coreutils}/bin/chmod 0700 \
                    ${lib.escapeShellArg "/home/${name}/.hermes/google"}
            ''
        );

        # Drop MCP servers not listed in the current MCP config.
        home.activation.hermesPruneMcp = lib.hm.dag.entryAfter [ "hermesAgentSetup" ] ''
            $DRY_RUN_CMD ${pruneMcpScript} \
                ${lib.escapeShellArg "/home/${name}/.hermes/config.yaml"} \
                ${lib.escapeShellArgs (lib.attrNames (cfg.mcpServers // agent.mcpServers))}
        '';
    };



    agentSubmodule = lib.types.submodule ({ name, ... }@submoduleArgs: let
        agentName = name;
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
                description = "SOUL.md for the agent, either a string or a file";
            };

            environmentFile = lib.mkOption {
                type = lib.types.str;
                default = config.age.secrets."hermes-${name}".path;
                description = "Secret path or agenix";
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
                description = "Extra settings, deepmerged with agent defaults";
            };

            extraPackages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [];
                example = lib.literalExpression "[ pkgs.pandoc pkgs.jq ]";
                description = "Tools the agent may call from its terminal.";
            };

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
                        Google accounts avaible to the agent via Google's API. 
                        Each accounts is handled seperately with its own capabilities and tokenfile, allowing for finegrained control over scopes. They are enforced via wrappers.
                    '';
                    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
                        options = {
                            capabilities = lib.mkOption {
                                type = googleLib.capabilityType;
                                default = [ ];
                                example = [ "mail.read" "mail.labels" "mail.rules" ];
                                description = ''
                                    Capabiltiies for one account, evaluated only during token generation. Later changes require reauth.
                                    Valid names:
                                    ${lib.concatMapStringsSep "\n" (c: "  * ${c}") googleLib.capabilityNames}
                                '';
                            };

                            address = lib.mkOption {
                                type = lib.types.nullOr lib.types.str;
                                default = null;
                                example = "hermes.agent.karl@gmail.com";
                                description = "Google address of the account, only useful for context";
                            };

                            purpose = lib.mkOption {
                                type = lib.types.str;
                                default = "";
                                example = "Read-only triage of Karl's personal mail. Never compose or send.";
                                description = "Context for the agent to provide context about the account and the purpose of it. Required to make the agent know how to access it, what to use it for and when to use it.";
                            };

                            publishing = lib.mkOption {
                                type = lib.types.enum [ "testing" "production" ];
                                default = "production";
                                description = "Status of the google app, required as testing-apps need reauth every 7 days";
                            };

                            project = lib.mkOption {
                                type = lib.types.nullOr lib.types.str;
                                default = null;
                                example = "hermes-personal-readonly";
                                description = "Documentation of the google app name";
                            };

                            scopes = lib.mkOption {
                                type = lib.types.listOf lib.types.str;
                                readOnly = true;
                                default = googleLib.scopesFor config.capabilities;
                                defaultText = lib.literalExpression
                                    "derived from `capabilities` via hermes/google/capabilities.nix";
                                description = "Read-only, scopes derived from capabilities";
                            };

                            tokenPath = lib.mkOption {
                                type = lib.types.str;
                                readOnly = true;
                                default = "/home/${agentName}/.hermes/google/${name}/google_token.json";
                                defaultText = lib.literalExpression
                                    "\"/home/<agent>/.hermes/google/<account>/google_token.json\"";
                                description = "Read-only, path to the token file needed for access";
                            };
                        };
                    }));
                };

                clientSecretFile = lib.mkOption {
                    type = lib.types.str;
                    default = config.age.secrets."google-${name}".path; 
                    description = "Secret file that enables OAuth procedure and lets agents use the app";
                };
            };


            extraGroups = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                example = [ "docker" ];
                description = "Additional groups the user belongs to. Most add root, so careful";
            };

            sshKeys = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
                example = [ "ssh-ed25519 AAAA... alice@laptop" ];
                description = "ssh-key used to a) encrypt the agenix secrets and b) access the terminal";
            };

            mobile.enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Make dashboard look like desktop app to make mobile access seemless";
            };

            dashboard = {
                enable = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Enable online dashboard";
                };

                port = lib.mkOption {
                    type = lib.types.port;
                    example = 9119;
                    description = "Port for the gateway and dashboard";
                };

                sessionTokenFile = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "/etc/hermes/${name}.token";
                    description = "Optional to add a permanent access token. Otherwise generates new access token on restart";
                };
            };

            # The gate needs these two in ${cfg.secretsDir}/${name}.env when
            # dashboard.enable is true (the username is set by the module):
            #     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<choose one>
            #     HERMES_DASHBOARD_BASIC_AUTH_SECRET=<openssl rand -base64 32>
            apiServerPort = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                example = 8642;
                description = "Add the agent as an OpenAI-API compatible LLM backend, added to model gateway";
            };

            mcpServers = lib.mkOption {
                type = lib.types.attrsOf lib.types.attrs;
                default = {};
                description = "Store MCP servers to be added alongside fleet-wide MCPs. Secrets should go in env-file (agenix)";
            };

            skills = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Curated skills from services/hermes/skills/, added via settings.skills.external_dirs.";
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
                description = "Add profiles to the agent to allow for specialised agents for tasks like research,coding, etc.";
            };
        };
    });
in {
    
    options.services.hermes-agents = {
        enable = lib.mkEnableOption "per-user Hermes agents via Home Manager";

        modelBaseUrl = lib.mkOption {
            type = lib.types.str;
            # Use unified gateway if active, else use model running on 8070 (Gemma)
            default =
                if options.services ? model-gateway
                then "http://127.0.0.1:${toString config.services.model-gateway.port}/v1"
                else "http://127.0.0.1:8070/v1";
            defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.services.model-gateway.port}/v1"'';
            description = "OpenAI-compatible base URL every agent talks to.";
        };

        defaultModel = lib.mkOption {
            type = lib.types.str;
            example = "Qwen3.8-27B";
            description = "Default model on default model-url to be used";
        };

        secretsDir = lib.mkOption {
            type = lib.types.str;
            default = "/etc/hermes";
            description = "Directory holding one <name>.env per agent.";
        };

        dashboard = {
            host = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "192.168.42.2";
                description = "Address the dashboard is reachable from, standard is 0.0.0.0";
            };

            interface = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "enp3s0";
                description = "Alternative to dashboardHost for machines without static IP";
            };
        };

        mobile = {
            rev = lib.mkOption {
                type = lib.types.str;
                default = "864514961e57a83ebe4684a480279be35534e8f1";
                description = "sremes/hermes-mobile commit the PWA is built from, for agents with `mobile.enable`";
            };

            hash = lib.mkOption {
                type = lib.types.str;
                default = "sha256-DVXku5yg5iK/FtXQ0k3bRFy1NpZxR6cb1H0wEzBrXLw=";
                description = "SRI hash of the source tree for `mobile.rev`.  Obtain with `nix flake prefetch --json github:sremes/hermes-mobile/<rev>`.";
            };
        };

        dependencyGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "messaging" ];
            description = "Hermes pyproject extras compiled into the venv. 'messaging' is Telegram, Discord and Slack. Shared by all agents";
        };

        extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [];
            description = "Extra packages to be installed for each agent";
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
            description = "MCP avaible fleet-wide, per-agent and per-profile";
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
            description = "Additional settings";
        };

        docling = {
            enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Enable pdf-parsing via docling";
            };

            url = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = 
                    if config.services.docling.enable 
                    then "http://127.0.0.1:${toString config.services.docling.port}"
                    else null;
                description = "url";
            };

            timeout = lib.mkOption {
                type = lib.types.int;
                default = 120;
                description = "Maximum time docling has for conversion";
            };
        };

        agents = lib.mkOption {
            type = lib.types.attrsOf agentSubmodule;
            default = {};
            description = "Users";
        };
    };

    config = let
        agentList = lib.attrValues cfg.agents;
        apiPorts = lib.filter (p: p != null) (map (a: a.apiServerPort) agentList);
        dashPorts = map (a: a.dashboard.port) (lib.filter (a: a.dashboard.enable) agentList);
        allPorts = dashPorts ++ apiPorts;

        allMcpEntries = lib.unique (
            lib.concatMap (agent:
                lib.attrValues agent.mcpServers
                ++ lib.concatMap (p: lib.attrValues p.mcpServers) (lib.attrValues agent.profiles)
            ) agentList
            ++ lib.attrValues cfg.mcpServers
        );

        requiredServices = lib.unique (lib.flatten (map (e:
            (e.meta or {}).requires.services or []
        ) allMcpEntries));

        candidateServices = lib.filter (s: options.services ? ${s}) (lib.unique (lib.flatten (
            map (e: (e.meta or {}).requires.services or [])
                (lib.attrValues (import ../lib.nix { inherit pkgs config lib; }).mcp)
        )));

    in lib.mkIf cfg.enable {
        assertions = [
            {
                # Every TCP port any agent binds, dashboards and API servers need to be different
                assertion = lib.length allPorts == lib.length (lib.unique allPorts);
                message = "services.hermes-agents: two agents share a dashboard.port or apiServerPort.";
            }
            {
                # Without either, the backend would bind Hermes' default
                assertion = dashPorts == [] || cfg.dashboard.host != null || cfg.dashboard.interface != null;
                message = "services.hermes-agents: an agent has dashboard.enable but neither dashboardHost nor dashboardInterface is set.";
            }
            {
                # The hook fails closed, so pointing it at nothing would turn every PDF read into a blocked tool call.  
                assertion = !cfg.docling.enable || (cfg.docling.url != null && !lib.hasSuffix "/" cfg.docling.url);
                message = "services.hermes-agents.docling.url must be non-empty and have no trailing slash.";
            }
        ];

        # Dashboards are LAN-facing by design; the auth gate is the lock.
        networking.firewall.allowedTCPPorts = allPorts;

        services =
            (lib.genAttrs candidateServices (s: {
                enable = lib.mkIf (lib.elem s requiredServices) true;
            }))
            //
            (lib.optionalAttrs (options.services ? model-gateway) {
                model-gateway = {
                    endpoints = lib.mapAttrs' (name: agent:
                        lib.nameValuePair "hermes-${name}" {
                            url = "http://127.0.0.1:${toString agent.apiServerPort}";
                            discovery = "probe";
                            priority = 50;
                        }
                    ) (lib.filterAttrs (_: a: a.apiServerPort != null) cfg.agents);
                };
            });



        systemd.tmpfiles.rules = [
            "d ${cfg.secretsDir} 0755 root root - -"
        ];

        users.groups = lib.mapAttrs (_: _: {}) cfg.agents;

        users.users = lib.mapAttrs (name: agent: {
            isNormalUser = true;
            description = "Hermes agent (${name})";
            group = name;
            extraGroups = agent.extraGroups;

            openssh.authorizedKeys.keys = agent.sshKeys;

            # Without linger, hermes is not reachable
            linger = true;
        }) cfg.agents;

        home-manager.users = lib.mapAttrs mkHome cfg.agents;        
        
        age.secrets = (
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
