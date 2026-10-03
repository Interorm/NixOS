{
    pkgs, config, lib,
    ...
}: let
    cfg = config.services.model-gateway;

    gatewayEnv = pkgs.python313Packages.python.withPackages (ps: [
        ps.fastapi
        ps.uvicorn
        ps.httpx
    ]);

    # Nix owns the topology, Python owns the behaviour.  Everything the service
    # needs to know about *your* network is generated here and handed over as
    # JSON, so adding a backend never means editing the .py.
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
        enable = lib.mkEnableOption "the unified model gateway";

        host = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Bind host, e.g. 0.0.0.0 for LAN, 127.0.0.1 for localhost";
        };

        port = lib.mkOption {
            type = lib.types.port;
            default = 8100;
        };

        refreshSeconds = lib.mkOption {
            type = lib.types.int;
            default = 60;
            description = "Determines how often the model catalogue is refreshed";
        };

        probeTimeout = lib.mkOption {
            type = lib.types.float;
            default = 5.0;
            description = "Determines how often the endpoint activity is checked";
        };

        defaultModel = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Sets default model if no model is specified";
        };

        endpoints = lib.mkOption {
            default = {};
            description = "Attribute-List of all endpoints";
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                options = {
                    url = lib.mkOption {
                        type = lib.types.str;
                        example = "http://127.0.0.1:8070";
                    };

                    discovery = lib.mkOption {
                        type = lib.types.enum [ "probe" "static" ];
                        default = "probe";
                        description = "static-discovery endpoints are NOT polled by refreshs, stopping unneccsary server starts for WOL machines";
                    };

                    models = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [];
                        description = "Model IDs to put in the catalogue, required for static endpoints";
                    };

                    prefix = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        example = "pc/";
                        description = "Model-prefix; required when multiple machines serve the same model";
                    };

                    healthPath = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                    };

                    priority = lib.mkOption {
                        type = lib.types.int;
                        default = 100;
                        description = "Higher wins when two endpoints expose the same id.";
                    };

                    timeout = lib.mkOption {
                        type = lib.types.float;
                        default = 600.0;
                        description = "Timeout before a endpoint is declared unreachable";
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

                DynamicUser = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateDevices = true;
                NoNewPrivileges = true;

                Restart = "always";
                RestartSec = "5";
            };
        };

        networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
}
