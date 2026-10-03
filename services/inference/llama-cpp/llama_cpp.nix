{
    pkgs, config, lib,
    ...
}: let

    cfg = config.service.llama_cpp;

    llamacpp = (pkgs.llama-cpp.override {
        cudaSupport = true;
    }).overrideAttrs (oldAttrs: {
        cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
            "-DGGML_CUDA=" + (if cfg.cuda then "ON" else "OFF")
            "-DGGML_CUDA_F16=OFF"
            "-DCMAKE_CUDA_ARCHITECTURES=" + (toString cfg.cuda_architecture) 
        ];
    });

    settingsArgs = lib.concatStringsSep " " (lib.concatMap (name: value:
        if value == true
        then [ "--${name}" ]
        else if value == false
        then [ "--no-${name}" ]
        else if lib.isList value
        then lib.concatMap (v: [ "--${name}" (toString v) ]) value
        else [ "--${name}" (toString value) ]
    ) cfg.settings);

in {
    options.service.llama_cpp = {
        cuda = lib.mkOption = { type = lib.types.bool; default = true; };

        cuda_architecture = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null; #For older GPUs
            description = "Set the cuda architecture to get the correct llama-cpp version";
        };


        modelGateway = lib.mkOption {
            type = lib.types.bool;
            default = config.service.model-gateway.enable or false;
            description = "Automatically add all models from llama-cpp to model-gateway";
        };


        instances = lib.mkOption {
            default = {};
            description = "List of all models provided by llama-cpp";
            type = lib.types.attrsOf (lib.types.submodule ({names, ...}: {
                options = {
                    host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };

                    port = lib.mkOption { type = lib.types.port; };


                    model = lib.types.attrOf (lib.types.submodule ({names, ...}: {
                        options = {
                            repo = lib.mkOption { lib.types.str; };
                            file = lib.mkOption { lib.types.str; };
                            mtp = lib.mkoption { lib.types.nullOr lib.types.str; default = null; };
                            mmproj = lib.mkoption { lib.types.nullOr lib.types.str; default = null; };
                        };
                    }));

                    device = lib.mkOption { type = lib.types.nullOr lib.types.int; };

                    arguements = lib.mkOption {
                        default = {};
                        type = lib.types.attrsOf (lib.types.oneOf [
                            lib.types.str,
                            lib.types.int,
                            lib.types.bool;
                            (lib.types.listOf lib.types.str)
                        ]);
                        description = "Arguements used to serve the model";
                    };
                };
            }));
        };
    };

    config = lib.mkIf (cfg.instances != {})  {

        assertion = [{
            assertion = lib.length (map (instance: instance.port) cfg.instances) == lib.length (lib.unique (map (instance: instance.port) cfg.instances));
            message = "All llama-cpp instances must have unique ports";
        }];

        imports = [ ../huggingface-models.nix ]; 
        environment.systemPackages = [ llamacpp ];
        
        services.huggingface-models.models = lib.mapAttrs (name: model: 
            { ${name} = { repo = m.model.repo; file = m.model.file; target = "${name}.gguf"; }; } // 
            lib.optionalAttrs (m.model.mtp != null) { "${name}-mtp" = { repo = m.model.repo; file = m.model.mtp; target = "${name}-mtp.gguf"; }; } //
            lib.optionalAttrs (m.model.image != null) { "${name}-mmproj" = { repo = m.model.repo; file = m.model.image; target = "${name}-mmproj.gguf"; }; }
        ) cgf.instances;

        systemd.services = lib.mapAttrs (name: m: {
            description = "llama.cpp server (${name})";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" "hf-model-${name}.service" ] 
                ++ ( if m.model.mtp != null then ["hf-model-${name}-mtp.service"] else [] ) 
                ++ ( if m.model.image != null then ["hf-model-${name}-mmproj.service"] else [] );
            wants = [ "hf-model-${name}.service" ]  
                ++ ( if m.model.mtp != null then ["hf-model-${name}-mtp.service"] else [] ) 
                ++ ( if m.model.image != null then ["hf-model-${name}-mmproj.service"] else [] );

            serviceConfig = {
                Type = "simple";
                Environment = (if (m.device != null) then "CUDA_VISIBLE_DEVICES=${toString m.device}");
                ExecStart = lib.escapeShellArgs (
                    [ "${llamacpp}/bin/llama-server" "--model" config.services.huggingface-models.paths.${name} ]
                    ++ lib.mkIf (m.model.mtp != null) [ "--model-draft" config.services.huggingface-models.paths.${name}-mtp ]
                    ++ lib.mkIf (m.model.image != null) [ "--mmproj" config.services.huggingface-models.paths.${name}-mmproj ]
                    ++ [ "--alias" "${name}" ]
                    ++ lib.flatten (lib.mapAttrs settingArgs m.arguements)
                );
                Restart = "always";
                RestartSec = "5";
            };
        }) cfg.instances;

        networking.firewall.allowedTCPPorts = lib.map (m: m.port) (lib.attrValues cfg.instances);

        services.model-gateway.endpoints = lib.mkMerge (lib.mapAttrsToList (name: m: {
            ${name} = { url = "http://${m.host}:${toString m.port}"; };
        }) cfg.instances);

    };
}