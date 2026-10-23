{
    pkgs, config, options, lib,
    ...
}: let
    cfg = config.services.strata;

    packages = import ./package.nix {
        inherit pkgs lib;
        cudaArchitectures = cfg.cuda_architecture;
    };

    unitBase = name: lib.replaceStrings ["/" " "] ["-" "-"] name;
    unitName = name: "strata-${unitBase name}";
    prepareName = name: "strata-prepare-${unitBase name}";

    defaultInstances = lib.attrNames (lib.filterAttrs (_: m: m.isDefault) cfg.instances);
    defaultInstance =
        if defaultInstances != [] then lib.head defaultInstances
        else if lib.length (lib.attrNames cfg.instances) == 1
        then lib.head (lib.attrNames cfg.instances)
        else null;

    # Context lengths past the trained 262,144 needs yarn; this auto infers the factor
    defaultContext = 262144;
    scalingRequired = m: m.scaling.enable && (m.maxContext > defaultContext || m.scaling.factor != null);
    scalingFactor = m:
        if m.scaling.enable && m.scaling.factor != null then trimFloat m.scaling.factor
        else if m.maxContext > defaultContext && m.scaling.enable then trimFloat (m.maxContext * 1.0 / defaultContext)
        else "1";
    # Nix's toString renders a float as "1.500000", this corrects
    trimFloat = f: let
        s = toString f;
        trimmed = lib.strings.removeSuffix "." (
            lib.strings.removeSuffix "0" (
            lib.strings.removeSuffix "0" (
            lib.strings.removeSuffix "0" (
            lib.strings.removeSuffix "0" (
            lib.strings.removeSuffix "0" (
            lib.strings.removeSuffix "0" s))))));
    in if lib.strings.hasInfix "." s then trimmed else s;

    # The engine takes `--flag value` pairs; the same translation as ninfer, llamacpp
    argPairs = attrs: lib.concatLists (lib.mapAttrsToList (name: value:
        if value == null then []
        else if value == true then [ "--${name}" ]
        else if value == false then [ "--no-${name}" ]
        else if lib.isList value then lib.concatMap (v: [ "--${name}" (toString v) ]) value
        else [ "--${name}" (toString value) ]
    ) attrs);


    # The engine reads the prepared pack, not the GGUF, so each instance has a per-instance state dir holding what `iq_pack.py` / `mtp_pack.py` produced.
    stateDir = name: "/var/lib/strata/${name}";
    packDir = name: "${stateDir name}/pack";
    mtpDir = name: "${stateDir name}/mtp";

    engineArgs = name: m:
        [ "--pack" (packDir name)
          "--native" config.services.huggingface-models.paths."${name}-shard1"
        ]
        ++ lib.optionals (m.model.pleIdx != null) [
            "--ple-gguf"
            config.services.huggingface-models.paths."${name}-shard${toString m.model.pleIdx}"
        ]
        ++ [ "--expert-profile" "${packages.strata-serve}/share/strata/data/${m.model.expertProfile}"
             "--expert-cache" "auto"
             "--prefill" "auto"
             "--spec" (toString m.spec)
             "--spec-min-p" "0.5"
             "--mtp" "${mtpDir name}/rt"
             "--max-context" (toString m.maxContext)
        ]
        ++ lib.optionals (scalingRequired m) [
            "--rope-scaling" "yarn"
            "--rope-scale" (scalingFactor m)
        ]
        ++ argPairs m.arguements;

    # serve/server.py is driven by a JSON run config rather than by flags, so the module generates that file into the store.  Keys and their meanings are upstream's (setup.py writes the same shape).
    runConfig = name: m: pkgs.writeText "strata-${name}.json" (builtins.toJSON ({
        exe = "${packages.strata-engine}/bin/strata";
        args = engineArgs name m;
        cwd = "${packages.strata-serve}/share/strata";
        tokenizer = "${packDir name}/tokenizer";
        model_name = name;
        port = m.port;
        host = m.host;
        log = "${stateDir name}/engine.log";
        open_browser = false;
    } // lib.optionalAttrs (m.parallel != null) {
        parallel = m.parallel;
    } // m.extraConfig));

    # One-shot preparation: upstream's iq_pack.py turns the GGUF into the engine's pack layout and mtp_fetch/mtp_pack build the draft layer. This is the only part that cannot be a pure derivation -- it reads the multi-GB weights from the mutable model dir -- so it is a guarded oneshot unit keyed on its own output, exactly like hf-model-*.
    prepareUnit = name: m: lib.nameValuePair (prepareName name) {
        description = "Prepare ${name} for the Strata engine (pack + draft layer)";

        after = [ "network-online.target" ]
            ++ map (i: "hf-model-${name}-shard${toString i}.service") (lib.range 1 lib.length m.model.shards);
        wants = [ "network-online.target" ]
            ++ map (i: _: "hf-model-${name}-shard${toString i}.service") (lib.range 1 lib.length m.model.shards);
        requires = map (i: _: "hf-model-${name}-shard${toString i}.service") (lib.range 1 (lib.length m.model.shards));

        unitConfig.ConditionPathExists = "!${packDir name}/native_experts.txt";

        path = [ packages.pythonEnv pkgs.coreutils ];

        environment = {
            # tools/_paths.py also finds this itself via <root>/third_party/llama.cpp/gguf-py, which the package puts in place; set explicitly so the resolution does not depend on the tools' cwd.
            STRATA_GGUF_PY = "${packages.strata-serve}/${packages.strata-serve.ggufPy}";
            PYTHONPATH = "${packages.strata-serve}/share/strata";
            HF_HOME = "${config.services.huggingface-models.directory}/.cache";
            HF_HUB_DISABLE_TELEMETRY = "1";
        };

        serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "infinity";
            StateDirectory = "strata/${name}";
            Restart = "on-failure";
            RestartSec = "60";
        };

        script = ''
            set -euo pipefail
            tools=${packages.strata-serve}/share/strata/tools

            # Pack the experts. Written to a staging dir and renamed, so an interrupted run never leaves a half pack that looks complete to the ConditionPathExists above.
            if [ ! -f ${lib.escapeShellArg "${packDir name}/native_experts.txt"} ]; then
                rm -rf ${lib.escapeShellArg "${packDir name}.staging"}
                python "$tools/iq_pack.py" \
                    --gguf ${lib.escapeShellArg config.services.huggingface-models.paths."${name}-shard1"} \
                    --out ${lib.escapeShellArg "${packDir name}.staging"} \
                    ${lib.escapeShellArgs m.model.packArgs}
                mv -fT ${lib.escapeShellArg "${packDir name}.staging"} ${lib.escapeShellArg (packDir name)}
            fi

            # The MTP draft layer: ~5 GB of tensors from the original Qwen checkpoint, then repacked. mtp_fetch resumes, so a failed run is retried by Restart= rather than restarted from zero.
            mkdir -p ${lib.escapeShellArg (mtpDir name)}
            if [ ! -f ${lib.escapeShellArg "${mtpDir name}/mtp-q2_0.gguf"} ]; then
                python "$tools/mtp_fetch.py" fetch --out ${lib.escapeShellArg (mtpDir name)}
                python "$tools/mtp_pack.py" \
                    --src ${lib.escapeShellArg (mtpDir name)} \
                    --experts q2_0 \
                    --out ${lib.escapeShellArg "${mtpDir name}/mtp-q2_0.gguf"}
            fi
            mkdir -p ${lib.escapeShellArg "${mtpDir name}/rt"}
        '';
    };

    serveUnit = name: m: lib.nameValuePair (unitName name) {
        description = "Strata inference server for model ${name}";

        after = [ "network.target" "${prepareName name}.service" ];
        wants = [ "${prepareName name}.service" ];
        requires = [ "${prepareName name}.service" ];

        unitConfig.ConditionPathExists = "${packDir name}/native_experts.txt";

        serviceConfig = {
            Type = "simple";

            Environment = lib.optional (m.device != null)
                "CUDA_VISIBLE_DEVICES=${toString m.device}";

            ExecStart = lib.escapeShellArgs ([
                "${packages.strata-serve}/bin/strata-serve"
                "--engine" "strata"
                "--config" "${runConfig name m}"
                "--port" (toString m.port)
                "--host" m.host
            ] ++ lib.optional m.noApiKey "--no-api-key"
              ++ lib.optionals (m.parallel != null)
                [ "--parallel" (toString m.parallel) ]);

            StateDirectory = "strata/${name}";
            WorkingDirectory = stateDir name;

            LimitMEMLOCK = "infinity";

            Restart = "always";
            RestartSec = "10";
        };
    };
    # Remote control surface for the homeserver's llama-proxy.  The proxy SSHes in and runs `sudo stratactl <verb>`; everything it is allowed to do is enumerated here, so the sudo rule below can be a single NOPASSWD entry on one binary instead of blanket root.  (Same shape as ninferctl; the prepare unit is reached via Requires= on the serve unit, so start/stop only ever name the serve unit.)
    stratactl = pkgs.writeShellScriptBin "stratactl" ''
        set -euo pipefail
        # Generated from services.strata.instances -- the only units this tool
        # may touch.  $2 is used solely as a key into this map, never spliced
        # into a unit name, so the broad NOPASSWD rule cannot be turned into
        # "systemctl anything".
        declare -A units=(
            ${lib.concatStringsSep "\n            " (lib.mapAttrsToList
                (name: _: "[${lib.escapeShellArg name}]=${lib.escapeShellArg "${unitName name}.service"}")
                cfg.instances)}
        )
        declare -A prepares=(
            ${lib.concatStringsSep "\n            " (lib.mapAttrsToList
                (name: _: "[${lib.escapeShellArg name}]=${prepareName name}.service")
                cfg.instances)}
        )
        default_instance=${lib.escapeShellArg (if defaultInstance == null then "" else defaultInstance)}
        verb="''${1:-}"; inst="''${2:-$default_instance}"
        usage() {
            echo "usage: stratactl {start|stop|restart|status} [instance]" >&2
            echo "       stratactl {list|poweroff}" >&2
            echo "instances: ''${!units[*]}" >&2
            exit 2
        }
        case "$verb" in
            list)     printf '%s\n' "''${!units[@]}"; exit 0 ;;
            poweroff) exec systemctl poweroff ;;
            start|stop|restart|status) ;;
            *) usage ;;
        esac
        [ -n "$inst" ] || {
            echo "stratactl: no instance given and no instance sets isDefault" >&2
            usage
        }
        unit="''${units[$inst]:-}"
        [ -n "$unit" ] || { echo "stratactl: unknown instance '$inst'" >&2; usage; }
        case "$verb" in
            status) exec systemctl is-active "$unit" ;;
            start)
                # The serve unit Requires= the prepare unit; pulling it in first makes `start` self-seeding: on the very first start the shards download (the prepare unit Requires= the hf-model units) and the pack is built, and the serve unit's ConditionPathExists then passes.  With the pack in place the prepare unit is a no-op (its own condition skips it).
                systemctl start "''${prepares[$inst]}"
                exec systemctl start "$unit"
                ;;
            *)      exec systemctl "$verb" "$unit" ;;
        esac
    '';
in {
    imports = [ ../huggingface-models.nix ];

    options.services.strata = {
        enable = lib.mkEnableOption "the Strata MoE inference server";

        cuda_architecture = lib.mkOption { type = lib.types.str; default = "120"; };

        modelGateway = lib.mkOption {
            type = lib.types.bool;
            default = (options.services ? model-gateway) && (config.services.model-gateway.enable or false);
            description = "Register every instance with model-gateway.";
        };

        instances = lib.mkOption {
            default = {};
            description = "Models served by the Strata engine.";
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                options = {
                    host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };
                    port = lib.mkOption { type = lib.types.port; };

                    isDefault = lib.mkOption { type = lib.types.bool; default = false; };
                    noApiKey = lib.mkOption { type = lib.types.bool; default = true; };

                    model = {
                        repo = lib.mkOption { type = lib.types.str; };
                        revision = lib.mkOption { type = lib.types.str; default = "main"; };
                        shards = lib.mkOption {
                            type = lib.types.listOf lib.types.str;
                            description = "Every shard of the release, in order. Shard 1 is the anchor (metadata, --native); iq_pack.py finds the rest by filename.";
                        };
                        pleIdx = lib.mkOption {
                            type = lib.types.nullOr lib.types.int;
                            default = null;
                            description = "Index of the shard holding the N-grams. Defaults to last shard";
                        };
                        expertProfile = lib.mkOption {
                            type = lib.types.str;
                            default = "expert-profile.bin";
                            example = "expert-profile-coder.bin";
                            description = "Expert profile to be used; Computed at start";
                        };
                        packArgs = lib.mkOption {
                            type = lib.types.listOf lib.types.str;
                            default = [];
                            example = [ "--compat-bf16" ];
                            description = "Extra arguments for iq_pack.py (Gyro needs --compat-bf16).";
                        };
                    };

                    parallel = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
                    spec = lib.mkOption { type = lib.types.int; default = 4; };

                    maxContext = lib.mkOption { type = lib.types.int; default = defaultContext; };
                    scaling = {
                        enable = lib.mkOption { type = lib.types.bool; default = true; };
                        factor = lib.mkOption { type = lib.types.nullOr lib.types.float; default = null; };
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
                        description = "Extra engine flags, keyed without the leading --.";
                    };
                    extraConfig = lib.mkOption {
                        type = lib.types.attrsOf lib.types.anything;
                        default = {};
                        description = "Extra keys merged into the generated run config JSON.";
                    };
                };
            }));
        };

        runConfigs = lib.mkOption {
            type = lib.types.attrsOf lib.types.package;
            readOnly = true;
            description = "Read only configs for running the different models.";
        };

        engineArgv = lib.mkOption {
            type = lib.types.attrsOf (lib.types.listOf lib.types.str);
            readOnly = true;
            description = "Read-only map from instance name to the engine argv it is started with.";
        };
    };

    config = lib.mkIf (cfg.enable && cfg.instances != {}) {
        assertions = [
            {
                assertion = lib.length defaultInstances <= 1;
                message = "services.strata: only one instance may set isDefault = true, but these do: "
                    + lib.concatStringsSep ", " defaultInstances;
            }
            {
                assertion = let ports = lib.mapAttrsToList (_: m: m.port) cfg.instances;
                    in ports == lib.unique ports;
                message = "services.strata: every instance must have a unique port.";
            }
            {
                # The serve unit only passes --no-api-key when the instance
                # opts in, so a non-loopback host must declare that explicitly.
                assertion = lib.all
                    (m: m.noApiKey || lib.elem m.host [ "127.0.0.1" "::1" "localhost" ])
                    (lib.attrValues cfg.instances);
                message = ''
                    services.strata: an instance listening on a non-loopback
                    host serves the model to anyone who can reach the port.
                    Set noApiKey = true to accept that explicitly.
                '';
            }
        ];

        environment.systemPackages = [ packages.strata-engine packages.strata-serve stratactl ];

        # The proxy SSHes in as karl and runs `sudo stratactl ...`; the unit names are pinned inside the script, so one NOPASSWD entry on one binary is the whole grant (same rule ninfer gets for ninferctl).
        security.sudo.extraRules = [{
            users = [ "ALL" ];
            commands = [{
                command = "/run/current-system/sw/bin/stratactl";
                options = [ "NOPASSWD" ];
            }];
        }];

        services = {
            strata.runConfigs = lib.mapAttrs runConfig cfg.instances;
            strata.engineArgv = lib.mapAttrs engineArgs cfg.instances;

            huggingface-models.models = lib.mkMerge (lib.mapAttrsToList (name: m:
                lib.listToAttrs (lib.imap0 (i: file:
                    lib.nameValuePair "${name}-shard${toString (i+1)}" {
                        repo = m.model.repo;
                        revision = m.model.revision or "main";
                        file = file;
                        target = "${name}-${lib.last (lib.splitString "/" file)}";
                    }
                ) m.model.shards)
            ) cfg.instances);
        } // lib.optionalAttrs ((options.services ? model-gateway) && cfg.modelGateway) {
            model-gateway.endpoints = lib.mkMerge
                (lib.mapAttrsToList (name: m: {
                    ${name} = { url = "http://${m.host}:${toString m.port}"; };
                }) cfg.instances);
        };

        systemd.services =
            lib.mapAttrs' prepareUnit cfg.instances
            // lib.mapAttrs' serveUnit cfg.instances;

        systemd.tmpfiles.rules = [ "d /var/lib/strata 0755 root root - -" ];

        networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: m: m.port)
            (lib.filterAttrs (_: m: !lib.elem m.host [ "127.0.0.1" "::1" "localhost" ]) cfg.instances);
    };
}
