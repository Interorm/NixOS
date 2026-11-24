{
    pkgs, config, lib,
    cudaPackages,
    ...
}: let
    cfg = config.services.trellis2;
    hf = config.services.huggingface-models;
    llama = config.services.llama-cpp;

    loopback = [ "127.0.0.1" "::1" "localhost" ];

    # The four Hub repos the shape pipeline loads, fetched by the
    # huggingface-models units.  `include` keeps it to the shape stage:
    # ~11 GB instead of ~25 GB for the full repos.
    weights = {
        trellis2 = {
            repo = "microsoft/TRELLIS.2-4B";
            revision = "af44b45f2e35a493886929c6d786e563ec68364d";
            include = [
                "pipeline.json"
                "ckpts/ss_flow_img_dit_1_3B_64_bf16.*"
                "ckpts/slat_flow_img2shape_dit_1_3B_*"
                "ckpts/shape_dec_next_dc_f16c32_fp16.*"
            ];
        };
        image_large = {
            repo = "microsoft/TRELLIS-image-large";       # sparse-structure decoder only
            revision = "25e0d31ffbebe4b5a97464dd851910efc3002d96";
            include = [ "ckpts/ss_dec_conv3d_16l8_fp16.*" ];
        };
        dinov3 = {
            repo = "facebook/dinov3-vitl16-pretrain-lvd1689m";   # gated: needs HF token
            revision = "ea8dc2863c51be0a264bab82070e3e8836b02d51";
            include = [ "*.json" "model.safetensors" ];
        };
        rmbg = {
            repo = "briaai/RMBG-2.0";                     # gated: needs HF token
            revision = "6a88d6a65119856a743be87ec1e6bee6f08e1f93";
            include = [ "*.py" "*.json" "model.safetensors" ];
        };
    };
    hfName = key: "trellis2-${key}";
    hfUnits = map (key: "hf-model-${hfName key}.service") (lib.attrNames weights);

    # 61 -> "6.1"
    capability = let a = toString cfg.cuda_architecture;
        in "${lib.substring 0 (lib.stringLength a - 1) a}.${lib.substring (lib.stringLength a - 1) 1 a}";

    sharedUnit = "${cfg.shareGpuWith}.service";

    configFile = pkgs.writeText "trellis2-stl.json" (builtins.toJSON {
        inherit (cfg) host port;
        output_dir = "/var/lib/trellis2/outputs";
        default_resolution = cfg.defaultResolution;
        max_num_tokens = cfg.maxNumTokens;
        models = lib.mapAttrs (key: _: hf.paths.${hfName key}) weights;
    });
in {
    options.services.trellis2 = {
        enable = lib.mkEnableOption "TRELLIS.2 image-to-STL web UI (started on demand, not at boot)";

        package = lib.mkOption {
            type = lib.types.package;
            default = import ./package.nix {
                inherit pkgs lib cudaPackages;
                cudaCapability = capability;
            };
            defaultText = lib.literalMD "TRELLIS.2 built from `./package.nix` for `cuda_architecture`";
        };

        host = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; };
        port = lib.mkOption { type = lib.types.port; default = 7860; };

        shareGpuWith = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Gemma4-E4B";
            description = ''
                Name of a services.llama-cpp instance that owns the same GPU.
                TRELLIS.2 then runs on that instance's device, starting it
                stops the instance (Conflicts=), and stopping TRELLIS.2 starts
                the instance again.
            '';
        };

        device = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = if cfg.shareGpuWith != null then llama.instances.${cfg.shareGpuWith}.device else null;
            defaultText = lib.literalMD "the device of `shareGpuWith`";
            description = "CUDA_VISIBLE_DEVICES index (nvidia-smi index).";
        };

        cuda_architecture = lib.mkOption {
            type = lib.types.int;
            default = llama.cuda_architecture;
            defaultText = lib.literalExpression "config.services.llama-cpp.cuda_architecture";
            description = "Compute capability the CUDA extensions are compiled for, e.g. 61.";
        };

        defaultResolution = lib.mkOption {
            type = lib.types.enum [ "512" "1024_cascade" ];
            default = "512";
            description = "Preselected resolution in the UI. 1024 is not known to fit in 11 GB.";
        };

        maxNumTokens = lib.mkOption {
            type = lib.types.int;
            default = 49152;
            description = "Token cap for the 1024 cascade; lower it if 1024 runs out of VRAM.";
        };
    };

    config = lib.mkIf cfg.enable {
        assertions = [
            {
                assertion = lib.versions.major cudaPackages.cudaMajorMinorVersion == "12"
                    || cfg.cuda_architecture >= 75;
                message = "services.trellis2: CUDA ${cudaPackages.cudaMajorMinorVersion} cannot target sm_${toString cfg.cuda_architecture}; pass cudaPackages_12_x.";
            }
            {
                assertion = cfg.shareGpuWith == null || llama.instances ? ${cfg.shareGpuWith};
                message = "services.trellis2.shareGpuWith = \"${toString cfg.shareGpuWith}\" is not a services.llama-cpp instance.";
            }
        ];

        services.huggingface-models.models = lib.mapAttrs' (key: w: lib.nameValuePair (hfName key) {
            inherit (w) repo revision include;
            target = hfName key;
        }) weights;

        systemd.services.trellis2 = {
            description = "TRELLIS.2 image-to-STL"
                + lib.optionalString (cfg.shareGpuWith != null) " (borrows the GPU of ${cfg.shareGpuWith})";
            # No wantedBy: `systemctl start trellis2` when you want to print something.
            # Any ordering edge makes systemd finish stopping the conflicting
            # unit before this one starts (else both could hold VRAM briefly).
            after = [ "network.target" ] ++ hfUnits
                ++ lib.optional (cfg.shareGpuWith != null) sharedUnit;
            wants = hfUnits;
            conflicts = lib.optional (cfg.shareGpuWith != null) sharedUnit;
            # Deliberately no ConditionPathExists on the weights: a skipped start
            # would still stop the shared instance via Conflicts= but never run
            # ExecStopPost.  Missing weights make the process exit instead, and
            # ExecStopPost hands the GPU back.

            environment = {
                ATTN_BACKEND = "sdpa";
                PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
                FLEX_GEMM_USE_AUTOTUNE_CACHE = "0";
                FLEX_GEMM_AUTOSAVE_AUTOTUNE_CACHE = "0";
                HF_HUB_OFFLINE = "1";
                TRANSFORMERS_OFFLINE = "1";
                HOME = "/var/lib/trellis2";
            } // lib.optionalAttrs (cfg.device != null) {
                CUDA_VISIBLE_DEVICES = toString cfg.device;
            };

            serviceConfig = {
                Type = "simple";
                ExecStart = "${lib.getExe cfg.package} ${configFile}";
                # Hand the GPU back however TRELLIS.2 ended (stop, crash, OOM).
                # `+` = as root; --no-block so a conflict-triggered stop does not
                # wait on the very start that triggered it.
                ExecStopPost = lib.optional (cfg.shareGpuWith != null)
                    "+${config.systemd.package}/bin/systemctl start --no-block ${sharedUnit}";
                Restart = "no";
                TimeoutStartSec = "10min";

                DynamicUser = true;
                StateDirectory = "trellis2";
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                NoNewPrivileges = true;
            };
        };

        networking.firewall.allowedTCPPorts = lib.optional (!lib.elem cfg.host loopback) cfg.port;
    };
}
