{
    pkgs, config, lib,
    ...
}: let
    cfg = config.services.ninfer;

    argPairs = attrs: lib.concatLists (lib.mapAttrsToList (name: value:
        if value == true then [ "--${name}" ]
        else if value == false then [ "--no-${name}" ]
        else if lib.isList value then lib.concatMap (v: [ "--${name}" (toString v) ]) value
        else [ "--${name}" (toString value) ]
    ) attrs);

    unitName = name: "ninfer-${lib.replaceStrings ["/" " "] ["-" "-"] name}";


    cudaPackages = pkgs.cudaPackages_13_2;

    ninfer = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "ninfer";
        version = "unstable-2026-09-08";

        src = pkgs.fetchFromGitHub {
            owner = "Neroued";
            repo = "ninfer";

            rev = "641ef3e7af08fe8f58b769e9f7505f642975a9dc";
            hash = "sha256-RsGsaB93lezcebwYQT6cq4iL7PteRuY2/40OJ98H1CU=";
        };

        nativeBuildInputs = with pkgs; [
            cmake       
            ninja       
            pkg-config
            cudaPackages.cuda_nvcc
            autoAddDriverRunpath
        ];

        buildInputs = with pkgs; [
            curl        
            ffmpeg     
        ] ++ (with cudaPackages; [
            cuda_cudart
            cccl
            libcublas
            cuda_nvtx
        ]);

        cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_CUDA_ARCHITECTURES=${cfg.cuda_architecture}"
        ];

        # Upstream ships no `install` target, so the generic installPhase would
        # produce an empty $out.  cwd here is the cmake build dir.
        installPhase = ''
            runHook preInstall
            install -Dm755 apps/ninfer       "$out/bin/ninfer"
            install -Dm755 apps/ninfer-serve "$out/bin/ninfer-serve"
            runHook postInstall
        '';

        meta = {
            description = "From-scratch single-GPU CUDA inference engine";
            homepage = "https://github.com/Neroued/ninfer";
            license = lib.licenses.asl20;
            platforms = [ "x86_64-linux" ];
        };
    });


    # Remote control surface for the homeserver's llama-proxy.  The proxy SSHes
    # in and runs `sudo ninferctl <verb>`; everything it is allowed to do is
    # enumerated here, so the sudo rule below can be a single NOPASSWD entry on
    # one binary instead of blanket root.
    ninferctl = pkgs.writeShellScriptBin "ninferctl" ''
        set -euo pipefail

        # Generated from services.ninfer.instances — the only units this tool may touch.
        declare -A units=(
            ${lib.concatStringsSep "\n        " (lib.mapAttrsToList
                (name: _: ''[${lib.escapeShellArg name}]=${lib.escapeShellArg "${unitName name}.service"}'')
                cfg.instances)}
        )
        default_instance=${lib.escapeShellArg (lib.head (lib.attrNames cfg.instances))}

        verb="''${1:-}"; inst="''${2:-$default_instance}"

        usage() {
            echo "usage: ninferctl {start|stop|restart|status} [instance]" >&2
            echo "       ninferctl {list|poweroff}" >&2
            echo "instances: ''${!units[*]}" >&2
            exit 2
        }

        case "$verb" in
            list)     printf '%s\n' "''${!units[@]}"; exit 0 ;;
            poweroff) exec systemctl poweroff ;;
            start|stop|restart|status) ;;
            *) usage ;;
        esac

        unit="''${units[$inst]:-}"
        [ -n "$unit" ] || { echo "ninferctl: unknown instance '$inst'" >&2; usage; }

        case "$verb" in
            status) exec systemctl is-active "$unit" ;;
            *)      exec systemctl "$verb" "$unit" ;;
        esac
    '';
in {
    imports = [ ../huggingface-models.nix ];

    options.services.ninfer = {
        enable = lib.mkEnableOption "Enable NInfer inference server";

        cuda_architecture = lib.mkOption {
            type = lib.types.str; 
            default = "120a";
            description = "Set the cuda architecture to get the correct NInfer version";
        };

        modelGateway = lib.mkOption {
            type = lib.types.bool;
            default = config.services.model-gateway.enable or false;
            description = "Automatically add all models from llama-cpp to model-gateway";
        };

        instances = lib.mkOption {
            default = {};
            description = "List of all models provided by llama-cpp";
            type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
                options = {
                    host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };

                    port = lib.mkOption { type = lib.types.port; };


                    model = {
                        repo = lib.mkOption { type = lib.types.str; };
                        file = lib.mkOption { type = lib.types.str; };
                    };

                    device = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };

                    arguements = lib.mkOption {
                        default = {};
                        type = lib.types.attrsOf (lib.types.oneOf [
                            lib.types.str
                            lib.types.int
                            lib.types.bool
                            (lib.types.listOf lib.types.str)
                        ]);
                        description = "Arguements used to serve the model";
                    };
                };
            }));
        };
    };


    config = lib.mkIf (cfg.enable && cfg.instances != {}) {
        environment.systemPackages = [ ninfer ninferctl ];

        services.huggingface-models.models = lib.mkMerge (lib.mapAttrsToList (name: m:
            { ${name} = { repo = m.model.repo; file = m.model.file; target = "${name}.ninfer"; }; }
        ) cfg.instances);

        systemd.services = lib.mapAttrs' (name: m:
            lib.nameValuePair (unitName) {
                description = "NInfer inference server for model ${name}";

                after = [ "network.target" "hf-model-${name}.service" ];
                wants = [ "hf-model-${name}.service" ];

                unitConfig.ConditionPathExists = config.services.huggingface-models.paths.${name};

                serviceConfig = {
                    Type = "simple";

                    Environment = lib.optional (m.device != null) "CUDA_VISIBLE_DEVICES=${toString m.device}";
                    
                    ExecStart = lib.escapeShellArgs (
                        [ "${ninfer}/bin/ninfer-serve" ]
                        ++ [ "--model" config.services.huggingface-models.paths.${name} ]
                        ++ [ "--host" m.host "--port" (toString m.port) ]
                        ++ (argPairs m.arguements)
                    );
                };
        }) cfg.instances;

        networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: m: m.port)
            (lib.filterAttrs (_: m: !lib.elem m.host [ "127.0.0.1" "::1" "localhost" ]) cfg.instances);


        security.sudo.extraRules = [{
            users = [ "ALL" ];
            commands = [{
                command = "/run/current-system/sw/bin/ninferctl";
                options = [ "NOPASSWD" ];
            }];
        }];
    };
}
