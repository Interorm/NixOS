{
    pkgs, config, lib,
    cudaPackages,
    ...
}: let
    cfg = config.services.trellis2;
    hf = config.services.huggingface-models;
    llama = config.services.llama-cpp;

    loopback = [ "127.0.0.1" "::1" "localhost" ];

    # GGUF conversion of microsoft/TRELLIS.2-4B for trellis.cpp (public repo, no
    # HF token).  Q8 of the shape stage only: background removal (birefnet),
    # image conditioning (dinov3), sparse-structure flow + decoder, the 512/1024
    # shape flows and the shape decoder -- ~6.4 GB.  The tex_* files (texture
    # stage, ~4.6 GB at Q8) are left out because the service runs --no-texture.
    weights = {
        repo = "ilintar/trellis2-gguf";
        revision = "a57397bd3d351599d9729fc144b3f87c3f87d65b";
        quant = "q8";
        files = [
            "birefnet" "dinov3" "ss_flow" "ss_dec"
            "shape_flow_512" "shape_flow_1024" "shape_dec"
        ];
    };
    hfName = "trellis2";
    hfUnit = "hf-model-${hfName}.service";
    # trellis-server --models wants a flat directory of <stage>.gguf files.
    modelsDir = "${hf.paths.${hfName}}/${weights.quant}";

    sharedUnit = "${cfg.shareGpuWith}.service";

    checkWeights = pkgs.writeShellScript "trellis2-check-weights" ''
        for f in ${lib.concatMapStringsSep " " (f: "${f}.gguf") weights.files}; do
            [ -s "${modelsDir}/$f" ] || { echo "missing ${modelsDir}/$f (hf-model-${hfName} still downloading?)" >&2; exit 1; }
        done
    '';
in {
    options.services.trellis2 = {
        enable = lib.mkEnableOption "TRELLIS.2 image-to-3D (trellis.cpp, Q8, geometry only; started on demand, not at boot)";

        package = lib.mkOption {
            type = lib.types.package;
            default = import ./package.nix {
                inherit pkgs lib cudaPackages;
                cudaArchitecture = cfg.cuda_architecture;
            };
            defaultText = lib.literalMD "trellis.cpp built from `./package.nix` for `cuda_architecture`, plus the `trellis2-stl` client";
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
            description = "Compute capability the CUDA kernels are compiled for, e.g. 61.";
        };

        defaultResolution = lib.mkOption {
            type = lib.types.enum [ "512" "1024" ];
            default = "512";
            description = "Geometry resolution when a request does not set one (1024 = cascade). 1024 is not known to fit in 11 GB.";
        };

        maxFaces = lib.mkOption {
            type = lib.types.ints.positive;
            default = 300000;
            description = "QEM decimation face target when a request does not set one (trellis.cpp minimum: 1000).";
        };

        maxNumTokens = lib.mkOption {
            type = lib.types.int;
            default = 49152;
            description = "Token budget of the 1024 cascade; lower it if 1024 runs out of VRAM.";
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

        services.huggingface-models.models.${hfName} = {
            inherit (weights) repo revision;
            include = map (f: "${weights.quant}/${f}.gguf") weights.files;
            target = hfName;
        };

        environment.systemPackages = [ cfg.package ];     # trellis2-stl client

        systemd.services.trellis2 = {
            description = "TRELLIS.2 image-to-3D (trellis.cpp)"
                + lib.optionalString (cfg.shareGpuWith != null) " (borrows the GPU of ${cfg.shareGpuWith})";
            # No wantedBy: `systemctl start trellis2` when you want to print something.
            # Any ordering edge makes systemd finish stopping the conflicting
            # unit before this one starts (else both could hold VRAM briefly).
            after = [ "network.target" hfUnit ]
                ++ lib.optional (cfg.shareGpuWith != null) sharedUnit;
            wants = [ hfUnit ];
            conflicts = lib.optional (cfg.shareGpuWith != null) sharedUnit;
            # No ConditionPathExists on the weights: a skipped start would still
            # stop the shared instance via Conflicts= but never run ExecStopPost.
            # The ExecStartPre check below fails the start instead, and
            # ExecStopPost (which runs after a failed start too) hands the GPU back.

            environment = lib.optionalAttrs (cfg.device != null) {
                CUDA_VISIBLE_DEVICES = toString cfg.device;
            };

            serviceConfig = {
                Type = "simple";
                ExecStartPre = checkWeights;
                # CUDA_VISIBLE_DEVICES already narrows to one card, so ggml's device 0.
                # --no-texture is the base default; a request may still send texture=on,
                # which fails for lack of the tex_* weights rather than loading anything.
                ExecStart = lib.escapeShellArgs [
                    (lib.getExe cfg.package)
                    "--models" modelsDir
                    "--gpu" "0"
                    "--host" cfg.host
                    "--port" (toString cfg.port)
                    "--res" cfg.defaultResolution
                    "--faces" (toString cfg.maxFaces)
                    "--max-tokens" (toString cfg.maxNumTokens)
                    "--no-texture"
                    "--require-gpu"
                ];
                # Hand the GPU back however TRELLIS.2 ended (stop, crash, OOM).
                # `+` = as root; --no-block so a conflict-triggered stop does not
                # wait on the very start that triggered it.
                ExecStopPost = lib.optional (cfg.shareGpuWith != null)
                    "+${config.systemd.package}/bin/systemctl start --no-block ${sharedUnit}";
                Restart = "no";
                TimeoutStartSec = "10min";

                DynamicUser = true;
                StateDirectory = "trellis2";
                WorkingDirectory = "/var/lib/trellis2";
                PrivateTmp = true;
                ProtectHome = true;
                ProtectSystem = "strict";
                NoNewPrivileges = true;
            };
        };

        networking.firewall.allowedTCPPorts = lib.optional (!lib.elem cfg.host loopback) cfg.port;
    };
}
