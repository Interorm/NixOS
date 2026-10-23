{
    pkgs, config, options, lib,
    ...
}: let
    cfg = config.services.strata;

    packages = import ./package.nix {
        inherit pkgs lib;
        cudaArchitectures = cfg.cuda_architecture;
    };

    unitName = name: "strata-${lib.replaceStrings ["/" " "] ["-" "-"] name}";

    defaultInstances = lib.attrNames (lib.filterAttrs (_: m: m.isDefault) cfg.instances);
    defaultInstance =
        if defaultInstances != [] then lib.head defaultInstances
        else if lib.length (lib.attrNames cfg.instances) == 1
        then lib.head (lib.attrNames cfg.instances)
        else null;

    # Context lengths past the trained 262,144 need the rotary angles rescaled.
    # Upstream derives the factor as `context / 262144` (at least 1, exact --
    # 1.5 at 393K, 2 at 512K) and recommends yarn; inside the trained range it
    # deliberately stays at factor 1 so the angles are untouched.  Doing the
    # same arithmetic here keeps `maxContext` the single knob a host has to set.
    trainedContext = 262144;

    # Nix's toString renders a float as "1.500000"; upstream writes it with
    # "%g", so trailing zeros are trimmed to keep the rendered flag identical
    # to the one its measurements were taken with.
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

    ropeScaleFor = m:
        if m.ropeScale != null then trimFloat m.ropeScale
        else if m.maxContext <= trainedContext then "1"
        else trimFloat (m.maxContext * 1.0 / trainedContext);

    needsScaling = m: m.ropeScaling != null || m.maxContext > trainedContext;

    # The engine takes `--flag value` pairs; the same translation the ninfer and
    # llama-cpp modules use, so a host file reads the same way across engines.
    argPairs = attrs: lib.concatLists (lib.mapAttrsToList (name: value:
        if value == null then []
        else if value == true then [ "--${name}" ]
        else if value == false then [ "--no-${name}" ]
        else if lib.isList value then lib.concatMap (v: [ "--${name}" (toString v) ]) value
        else [ "--${name}" (toString value) ]
    ) attrs);

    modelDir = config.services.huggingface-models.directory;

    # The engine reads the prepared pack, not the GGUF, so each instance has a
    # per-instance state dir holding what `iq_pack.py` / `mtp_pack.py` produced.
    stateDir = name: "/var/lib/strata/${name}";
    packDir = name: "${stateDir name}/pack";
    mtpDir = name: "${stateDir name}/mtp";

    engineArgs = name: m:
        [ "--pack" (packDir name)
          "--native" config.services.huggingface-models.paths."${name}-shard1"
        ]
        # With a two-shard release the n-gram table is its own file and is
        # passed explicitly; with four shards the engine locates it from
        # shard 1 itself, which is the configuration upstream measured.
        ++ lib.optionals (m.model.shards <= 2) [
            "--ple-gguf" config.services.huggingface-models.paths."${name}-shard2"
        ]
        ++ [ "--expert-profile" "${packages.strata-serve}/share/strata/data/${m.model.expertProfile}"
             "--expert-cache" "auto"
             "--prefill" "auto"
             "--spec" (toString m.spec)
             "--spec-min-p" "0.5"
             "--mtp" "${mtpDir name}/rt"
             "--max-context" (toString m.maxContext)
        ]
        ++ lib.optionals (needsScaling m) [
            "--rope-scaling" (if m.ropeScaling != null then m.ropeScaling else "yarn")
            "--rope-scale" (ropeScaleFor m)
        ]
        ++ lib.optionals (m.maxContext > 8192) [ "--kv" m.kv ]
        ++ lib.optionals (m.kvResident != null) [ "--kv-resident" (toString m.kvResident) ]
        ++ argPairs m.arguements;

    # serve/server.py is driven by a JSON run config rather than by flags, so
    # the module generates that file into the store.  Keys and their meanings
    # are upstream's (setup.py writes the same shape).
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
    } // lib.optionalAttrs (m.aliases != []) {
        aliases = m.aliases;
    } // lib.optionalAttrs (m.vramReserveMib != null) {
        vram_reserve_mib = m.vramReserveMib;
    } // lib.optionalAttrs (m.idleUnloadSeconds != null) {
        idle_unload_s = m.idleUnloadSeconds;
    } // m.extraConfig));

    # One-shot preparation: upstream's iq_pack.py turns the GGUF into the
    # engine's pack layout and mtp_fetch/mtp_pack build the draft layer.  This
    # is the only part that cannot be a pure derivation -- it reads the
    # multi-gigabyte weights from the mutable model dir -- so it is a guarded
    # oneshot unit keyed on its own output, exactly like hf-model-*.
    prepareUnit = name: m: lib.nameValuePair "strata-prepare-${name}" {
        description = "Prepare ${name} for the Strata engine (pack + draft layer)";

        after = [ "network-online.target" "hf-model-${name}-shard1.service" "hf-model-${name}-shard2.service" ];
        wants = [ "network-online.target" "hf-model-${name}-shard1.service" "hf-model-${name}-shard2.service" ];
        requires = [ "hf-model-${name}-shard1.service" "hf-model-${name}-shard2.service" ];

        unitConfig.ConditionPathExists = "!${packDir name}/native_experts.txt";

        path = [ packages.pythonEnv pkgs.coreutils ];

        environment = {
            # tools/_paths.py also finds this itself via
            # <root>/third_party/llama.cpp/gguf-py, which the package puts in
            # place; set explicitly so the resolution does not depend on the
            # tools' cwd.
            STRATA_GGUF_PY = "${packages.strata-serve}/${packages.strata-serve.ggufPy}";
            PYTHONPATH = "${packages.strata-serve}/share/strata";
            HF_HOME = "${modelDir}/.cache";
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

            # Pack the experts. Written to a staging dir and renamed, so an
            # interrupted run never leaves a half pack that looks complete to
            # the ConditionPathExists above.
            if [ ! -f ${lib.escapeShellArg "${packDir name}/native_experts.txt"} ]; then
                rm -rf ${lib.escapeShellArg "${packDir name}.staging"}
                python "$tools/iq_pack.py" \
                    --gguf ${lib.escapeShellArg config.services.huggingface-models.paths."${name}-shard1"} \
                    --out ${lib.escapeShellArg "${packDir name}.staging"} \
                    ${lib.escapeShellArgs m.model.packArgs}
                mv -fT ${lib.escapeShellArg "${packDir name}.staging"} ${lib.escapeShellArg (packDir name)}
            fi

            # The MTP draft layer: ~5 GB of tensors from the original Qwen
            # checkpoint, then repacked. mtp_fetch resumes, so a failed run is
            # retried by Restart= rather than restarted from zero.
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

        wantedBy = lib.optional m.autoStart "multi-user.target";
        after = [ "network.target" "strata-prepare-${name}.service" ];
        wants = [ "strata-prepare-${name}.service" ];
        requires = [ "strata-prepare-${name}.service" ];

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
            ] ++ lib.optionals (m.parallel != null) [ "--parallel" (toString m.parallel) ]
              ++ lib.optional m.noApiKey "--no-api-key");

            StateDirectory = "strata/${name}";
            WorkingDirectory = stateDir name;

            # The engine pins the expert arena and the KV host copy, which is
            # tens of gigabytes; the default limits would refuse that.
            LimitMEMLOCK = "infinity";

            Restart = "always";
            RestartSec = "10";
        };
    };
in {
    imports = [ ../huggingface-models.nix ];

    options.services.strata = {
        enable = lib.mkEnableOption "the Strata MoE inference server";

        cuda_architecture = lib.mkOption {
            type = lib.types.str;
            default = "120";
            example = "89";
            description = ''
                CUDA compute capability to build the engine for, without the
                trailing "a" suffix (120 = RTX 50 / Blackwell consumer,
                89 = RTX 40, 86 = RTX 30, 75 = RTX 20).  Upstream refuses
                anything below 75.
            '';
        };

        modelGateway = lib.mkOption {
            type = lib.types.bool;
            # `options.services ? model-gateway` is an *options* read, not a
            # config read, so it is cycle-free and also false on a host that
            # never imports the gateway -- where defining its endpoints would
            # be an error even under an mkIf that is false.
            default = (options.services ? model-gateway)
                && (config.services.model-gateway.enable or false);
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

                    autoStart = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = ''
                            Start with the system.  Set false to leave the unit
                            to an external starter such as llama-proxy.
                        '';
                    };

                    model = {
                        repo = lib.mkOption {
                            type = lib.types.str;
                            example = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
                        };
                        revision = lib.mkOption {
                            type = lib.types.str;
                            default = "main";
                            description = "Pin a commit sha; \"main\" moves.";
                        };
                        shard1 = lib.mkOption {
                            type = lib.types.str;
                            description = "Path of shard 1 inside the repo (the weights the engine packs).";
                        };
                        shard2 = lib.mkOption {
                            type = lib.types.str;
                            description = "Path of shard 2 inside the repo (the n-gram / PLE table).";
                        };
                        shards = lib.mkOption {
                            type = lib.types.int;
                            default = 2;
                            description = ''
                                Total shard count of the release.  With two
                                shards the PLE table is passed explicitly; with
                                more the engine finds it from shard 1.
                            '';
                        };
                        expertProfile = lib.mkOption {
                            type = lib.types.str;
                            default = "expert-profile.bin";
                            example = "expert-profile-coder.bin";
                            description = ''
                                Expert ranking shipped in the engine's data/
                                dir.  The Coder release has its own.
                            '';
                        };
                        packArgs = lib.mkOption {
                            type = lib.types.listOf lib.types.str;
                            default = [];
                            example = [ "--compat-bf16" ];
                            description = "Extra arguments for iq_pack.py (Gyro needs --compat-bf16).";
                        };
                    };

                    maxContext = lib.mkOption {
                        type = lib.types.int;
                        default = 262144;
                        description = ''
                            Context window in tokens.  Past the trained 262144
                            the rotary angles are rescaled automatically
                            (yarn, factor = context / 262144), which upstream
                            still labels experimental.
                        '';
                    };

                    ropeScaling = lib.mkOption {
                        type = lib.types.nullOr (lib.types.enum [ "none" "linear" "yarn" ]);
                        default = null;
                        description = ''
                            Override the rope scaling method.  null picks yarn
                            when maxContext exceeds the trained length and
                            leaves the angles untouched below it.
                        '';
                    };

                    ropeScale = lib.mkOption {
                        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.float);
                        default = null;
                        example = 1.5;
                        description = ''
                            Override the derived rope scaling factor.  Accepts
                            a float, since upstream's own factors are not all
                            whole numbers (1.5 at 393K).
                        '';
                    };

                    kv = lib.mkOption {
                        type = lib.types.enum [ "fp16" "int8" "q4_0" "k8v4" ];
                        default = "int8";
                        description = ''
                            KV cache format above 8K context.  int8 is
                            upstream's default; q4_0 halves the memory but
                            measurably costs long-document precision.
                        '';
                    };

                    kvResident = lib.mkOption {
                        type = lib.types.nullOr lib.types.int;
                        default = null;
                        example = 32768;
                        description = ''
                            Keep the KV cache in RAM and only this many cells
                            in VRAM, freeing VRAM for experts.  Upstream turns
                            this on from 64K context.
                        '';
                    };

                    spec = lib.mkOption {
                        type = lib.types.int;
                        default = 4;
                        description = "Speculative decoding draft depth.";
                    };

                    parallel = lib.mkOption {
                        type = lib.types.nullOr lib.types.int;
                        default = null;
                        description = ''
                            Concurrent request slots.  Upstream serves ONE
                            request at a time unless this is set, and each
                            extra slot costs VRAM and expert-cache space.
                        '';
                    };

                    vramReserveMib = lib.mkOption {
                        type = lib.types.nullOr lib.types.int;
                        default = null;
                        description = "VRAM in MiB left free for other programs (engine default 700).";
                    };

                    idleUnloadSeconds = lib.mkOption {
                        type = lib.types.nullOr lib.types.int;
                        default = null;
                        description = ''
                            Unload the model after this many idle seconds so
                            another GPU workload can have the VRAM; the next
                            request loads it again.
                        '';
                    };

                    aliases = lib.mkOption {
                        type = lib.types.listOf lib.types.str;
                        default = [];
                        description = "Extra model names the server answers to.";
                    };

                    noApiKey = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = ''
                            Serve on the network without an API key.  Upstream
                            requires this to be explicit, because anyone who
                            can reach the port can then use the model.
                        '';
                    };

                    device = lib.mkOption {
                        type = lib.types.nullOr lib.types.int;
                        default = null;
                        description = "Pin to one GPU via CUDA_VISIBLE_DEVICES.";
                    };

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
            description = ''
                Read-only map from instance name to its generated engine run
                config.  Exposed so the rendered JSON can be inspected and
                diffed against what was declared, rather than only existing as
                an interpolated path inside ExecStart.
            '';
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
                assertion = lib.all (m: m.noApiKey || lib.elem m.host [ "127.0.0.1" "::1" "localhost" ])
                    (lib.attrValues cfg.instances);
                message = ''
                    services.strata: an instance listening on a non-loopback
                    host serves the model to anyone who can reach the port.
                    Set noApiKey = true to accept that explicitly.
                '';
            }
        ];

        environment.systemPackages = [ packages.strata-engine packages.strata-serve ];

        # Both shards are fetched through the existing model plumbing, so the
        # weights land in the same mutable dir as every other engine's.
        # One `services` key only: a dotted path plus a flat `services =` would
        # both declare the parent and fail to merge.  The gateway half is
        # guarded with optionalAttrs rather than mkIf, because on a host that
        # does not import model-gateway the attribute path itself must not
        # exist, and a false mkIf would still count as a definition of it.
        services = {
            strata.runConfigs = lib.mapAttrs runConfig cfg.instances;
            strata.engineArgv = lib.mapAttrs engineArgs cfg.instances;

            huggingface-models.models = lib.mkMerge (lib.mapAttrsToList (name: m: {
                "${name}-shard1" = {
                    repo = m.model.repo;
                    revision = m.model.revision;
                    file = m.model.shard1;
                    target = "${name}-shard1.gguf";
                };
                "${name}-shard2" = {
                    repo = m.model.repo;
                    revision = m.model.revision;
                    file = m.model.shard2;
                    target = "${name}-shard2.gguf";
                };
            }) cfg.instances);
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
