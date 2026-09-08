{
    pkgs, config, lib,
    ...
}: let
    cfg = config.services.model-gateway;

    # Same trio as llama-proxy.nix.  `withPackages` builds a symlink farm, so
    # importing both modules on one host does not build a second copy of
    # anything -- the two environments share every underlying store path.
    gatewayEnv = pkgs.python313Packages.python.withPackages (ps: [
        ps.fastapi
        ps.uvicorn
        ps.httpx
    ]);

    # Nix owns the topology, Python owns the behaviour.  Everything the service
    # needs to know about *your* network is generated here and handed over as
    # JSON, so adding a backend never means editing the .py.
    #
    # The key names are snake_case because that is what model-gateway.py reads;
    # the Nix-facing option names stay camelCase like the rest of nixpkgs.  This
    # attrset is the translation layer between the two conventions.
    configFile = pkgs.writeText "model-gateway-config.json" (builtins.toJSON {
        listen = {
            host = cfg.host;
            port = cfg.port;
        };
        refresh_seconds = cfg.refreshSeconds;
        probe_timeout = cfg.probeTimeout;
        default_model = cfg.defaultModel;

        endpoints = lib.mapAttrsToList (name: e: {
            inherit name;
            inherit (e) url discovery models prefix priority timeout;
            health_path = e.healthPath;
        }) cfg.endpoints;
    });
in {
    options.services.model-gateway = {
        # mkEnableOption only declares the switch.  Note that the *endpoints*
        # option below is declared unconditionally: modules may register
        # themselves whether or not the gateway is turned on, because declaring
        # data is always harmless.  Only the `config` block is gated.
        enable = lib.mkEnableOption "the unified model gateway";

        host = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = ''
                Bind address.  0.0.0.0 so other machines on the LAN (and any
                agent you run later) can use this as their single base URL.
                Set to 127.0.0.1 if you ever put a real reverse proxy in front.
            '';
        };

        port = lib.mkOption {
            type = lib.types.port;
            default = 8100;
            description = ''
                8100 keeps clear of everything already in use on the homeserver:
                8070 (llama-chat), 8080 (llama-coder), 8090 (llama-proxy).
            '';
        };

        refreshSeconds = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = ''
                How often the catalogue is rebuilt.  This is how long it takes
                for an `--alias` change on a backend to show up here.
            '';
        };

        probeTimeout = lib.mkOption {
            type = lib.types.float;
            default = 5.0;
            description = ''
                Per-probe timeout.  Only applies to discovery, never to
                forwarded traffic -- that uses the endpoint's own `timeout`.
            '';
        };

        defaultModel = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Qwen2.5-Coder-7B";
            description = ''
                Where to send a request that carries no "model" field.  Leaving
                this null makes such a request a 400 with an explanation, which
                is usually what you want: silent routing to an arbitrary model
                is a debugging nightmare.
            '';
        };

        endpoints = lib.mkOption {
            default = {};
            description = ''
                The backends to federate.  Each inference module registers its
                own entry here, so the catalogue assembles itself from whatever
                modules the host happens to import -- add llama-vision.nix later
                and it appears in the gateway without touching this file.
            '';
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                options = {
                    url = lib.mkOption {
                        type = lib.types.str;
                        example = "http://127.0.0.1:8070";
                        description = "Base URL, no trailing slash needed.";
                    };

                    discovery = lib.mkOption {
                        type = lib.types.enum [ "probe" "static" ];
                        default = "probe";
                        description = ''
                            "probe": GET {url}/v1/models on every refresh and
                            take the ids verbatim.  Correct for anything that is
                            always running.

                            "static": trust the `models` list below and only
                            poll `healthPath`.  Required for the wake-on-LAN
                            proxy: its /v1/models goes through the catch-all
                            route, which calls ensure_inference_ready() and
                            physically boots the PC.  Probing it once a minute
                            would keep the machine awake forever.
                        '';
                    };

                    models = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [];
                        description = ''
                            Model ids for `discovery = "static"`; ignored when
                            probing.  These stay in the catalogue even while the
                            backend is asleep -- otherwise a client could never
                            send the request that wakes it.
                        '';
                    };

                    prefix = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "pc/";
                        description = ''
                            Namespace for this endpoint's ids.  Only needed when
                            two backends serve the same id and you want both
                            reachable; the gateway logs a collision and drops the
                            lower-priority one otherwise.  Stripped again before
                            the request is forwarded.
                        '';
                    };

                    healthPath = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "/proxy/status";
                        description = ''
                            Cheap liveness path for static endpoints.  Must be a
                            route that does NOT trigger any side effect upstream.
                        '';
                    };

                    priority = lib.mkOption {
                        type = lib.types.int;
                        default = 100;
                        description = "Higher wins when two endpoints expose the same id.";
                    };

                    timeout = lib.mkOption {
                        type = lib.types.float;
                        default = 600.0;
                        description = ''
                            Read timeout for *forwarded* traffic, in seconds.
                            The wake-on-demand endpoint holds the connection open
                            across WoL, boot and a 30 GB VRAM load, so it needs a
                            far larger budget than an always-on server.
                        '';
                    };
                };
            }));
        };
    };

    config = lib.mkIf cfg.enable {
        environment.systemPackages = [ gatewayEnv ];

        environment.etc."model-gateway/main.py".source = ./model-gateway.py;
        environment.etc."model-gateway/config.json".source = configFile;

        systemd.services.model-gateway = {
            description = "Unified OpenAI-compatible gateway for all local models";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];

            # Both triggers matter.  Without the config one, `nixos-rebuild
            # switch` after adding an endpoint would rewrite /etc but leave the
            # running process holding the old catalogue until the next reboot.
            restartTriggers = [
                config.environment.etc."model-gateway/main.py".source
                config.environment.etc."model-gateway/config.json".source
            ];

            serviceConfig = {
                Type = "simple";
                ExecStart = "${gatewayEnv}/bin/python /etc/model-gateway/main.py";

                # Unlike llama-proxy, this process never SSHes anywhere, never
                # sends WoL packets and never touches the GPU -- it only speaks
                # HTTP to localhost.  So it gets no privileges at all.
                DynamicUser = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateDevices = true;
                NoNewPrivileges = true;

                Restart = "always";
                RestartSec = "5";
            };
        };

        # Lists merge across modules, so this adds to whatever the host already
        # opened rather than replacing it.
        networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
}
