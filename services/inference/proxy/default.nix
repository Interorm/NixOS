{
    pkgs, config, lib, options,
    ...
}: let
    cfg = config.services.llama-proxy;

    llamaProxyEnv = pkgs.python313Packages.python.withPackages (ps: [
        ps.fastapi
        ps.uvicorn
        ps.httpx
    ]);


    remoteNames = lib.attrNames cfg.remotes;        
    portFor = lib.listToAttrs (lib.imap0 (i: name:
        let m = cfg.remotes.${name};
        in lib.nameValuePair name (if m.port != null then m.port else cfg.port.min + i)
    ) remoteNames);

    config_perRemote = name: m: pkgs.writeText "llama-proxy-${name}.json" (builtins.toJSON {
        inherit name;
        listen = { host = cfg.host; port = portFor.${name}; };

        machine = { inherit (m) mac ip user; };
        engine = {
            url = "http://${m.ip}:${toString m.engine.port}"; 
            command = m.engine.command; 
        };
        
        powerManagement = { inherit (m.powerManager) enable idlePoll stopEngineAfter stopRemoteAfter; };
        dndFlag = if m.dndFlag then "/home/${m.user}/.llama-proxy/dnd.flag" else null;
    });
in {
    options.services.llama-proxy = {
        enable = lib.mkEnableOption "Enable the llama-proxy service.";

        port = {
            min = lib.mkOption { type = lib.types.port; default = 8090; };
            max = lib.mkOption { type = lib.types.port; default = cfg.port.min + 9; };
        };
        host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };

        model-gateway = lib.mkOption {
            type = lib.types.bool;
            default = config.services.model-gateway.enable or false;
            description = "Automatically add inference backends to model-gateway";
        };

        remotes = lib.mkOption {
            description = "Remote inference servers and their details";
            default = {};
            type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
                options = {
                    mac = lib.mkOption { type = lib.types.str; };
                    ip = lib.mkOption { type = lib.types.str; };
                    user = lib.mkOption { type = lib.types.str; };

                    port = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; description = "Optional fixed port"; };

                    engine = {
                        command = lib.mkOption { type = lib.types.str; default = "/run/current-system/sw/bin/ninferctl"; };
                        port = lib.mkOption { type = lib.types.port; default = 8080; };
                    };
                    models = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; }; 

                    powerManager = {
                        enable = lib.mkEnableOption "Enable power management for this remote";
                        idlePoll = lib.mkOption { type = lib.types.int; default = 1; };
                        stopEngineAfter = lib.mkOption { type = lib.types.int; default = 15; };    
                        stopRemoteAfter = lib.mkOption { type = lib.types.int; default = 30; };
                    };

                    dndFlag = lib.mkOption { type = lib.types.bool; default = false; };
                };
            }));        
        };
    };

    config = lib.mkIf (cfg.enable && cfg.remote) {

        assertions = [ 
            { assertion = cfg.port.min + (lib.length remoteNames) - 1 <= cfg.port.max;
              message = "llama-proxy: ${toString (lib.length remoteNames)} remotes exceed range " + "${toString cfg.port.min}-${toString cfg.port.max}."; }
            { assertion = lib.length (lib.unique (lib.attrValues portFor)) == lib.length remoteNames;
              message = "llama-proxy: duplicate listen ports: ${builtins.toJSON portFor}"; }
        ]
            ++ lib.mapAttrsToList (name: m: {
                    assertion = m.powerManager.stopRemoteAfter >= m.powerManager.stopEngineAfter;
                    message = "llama-proxy: remote '${name}': stopRemoteAfter must be >= stopEngineAfter.";
                }) cfg.remotes
            ++ lib.mapAttrsToList (name: m: {
                    assertion = !m.powerManager.enable || m.mac != null;
                    message = "llama-proxy: remote '${name}' has power management but no MAC address.";
                }) cfg.remotes;
        
        environment.systemPackages = with pkgs; [
            wakeonlan openssh iputils 
        ];

        environment.etc = 
            {"llama-proxy/main.py".source = ./llama-proxy.py;} // 
            lib.mapAttrs' (name: m:
                lib.nameValuePair "llama-proxy/${name}.json" { source = config_perRemote name m; }
            ) cfg.remotes;

        systemd.services = lib.mapAttrs' (name: m:
            lib.nameValuePair "llama-proxy-${name}" {
                description = "llama.cpp Inference Proxy Service for ${name}";

                wantedBy = [ "multi-user.target" ];
                after = [ "network-online.target" ];
                wants = [ "network-online.target" ];

                restartTriggers = [
                    config.environment.etc."llama-proxy/main.py".source
                    config.environment.etc."llama-proxy/${name}.json".source
                ];

                path = [ pkgs.iputils pkgs.wakeonlan pkgs.openssh ];

                serviceConfig = {
                    Type = "simple";
                    ExecStart = "${llamaProxyEnv}/bin/python /etc/llama-proxy/main.py"
                                + " --config /etc/llama-proxy/${name}.json";

                    Restart = "always";
                    RestartSec = "5";
                    
                    User = "llama-proxy";
                    StateDirectory = "llama-proxy";   
                };
            }
        ) cfg.remotes;

        networking.firewall.allowedTCPPorts = 
            lib.optionals (!lib.elem cfg.host [ "127.0.0.1" "::1" "localhost" ])
            (lib.attrValues portFor);


        users.users.llama-proxy = { 
            isSystemUser = true; 
            group = "llama-proxy"; 
            home = "/var/lib/llama-proxy"; 
        }; 
        users.groups.llama-proxy = {};

        services = lib.mkIf cfg.model-gateway {
            model-gateway.endpoints = lib.mapAttrs (name: m: {
                url = "http://localhost:${toString portFor.${name}}";
                discovery = if m.powerManager.enable then "static" else "probe";
                prefix = "";
            }) cfg.remotes;
        };
    };
}