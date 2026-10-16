{
    config, lib, pkgs,
    ...
}: let
    cfg = config.services.speaches;

    stt-hfPath = config.services.huggingface-models.paths.speaches-stt;
    tts-hfPath = config.services.huggingface-models.paths.speaches-tts;

    # Speaches resolves a repo id against a HF hub cache
    # ($HF_HUB_CACHE/models--<org>--<name>/{refs/main,snapshots/<ref>/...}),
    # so the downloaded directories are mounted into this fixed skeleton.
    hubDir    = "/hf-hub";
    hubFolder = repo: "models--${lib.replaceStrings [ "/" ] [ "--" ] repo}";
    hubSkeleton = pkgs.runCommand "speaches-hf-hub" {} (lib.concatMapStrings (repo: ''
        mkdir -p $out/${hubFolder repo}/refs $out/${hubFolder repo}/snapshots/main
        printf main > $out/${hubFolder repo}/refs/main
    '') [ config.services.speaches.stt-model config.services.speaches.tts-model ]);
in {
    imports = [ ../../llama.cpp/huggingface-models.nix ];

    options.services.speaches = {
        enable = lib.mkEnableOption "Enable Speaches API for Speach-Text conversions";

        port = lib.mkOption {
            type = lib.types.port;
            default = 8110;
        };

        ui = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Toggle UI";
        };

        gpu = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "1";
            description = "GPU index. If null, use CPU instead";
        };

        stt-model = lib.mkOption {
            type = lib.types.str;
            description = "HF-repo with the speach-to-text model";
        };

        tts-model = lib.mkOption {
            type = lib.types.str;
            description = "HF-repo with the text-to-speech model";
        };
    };

    config = lib.mkIf cfg.enable {
        services.huggingface-models.models = {
            speaches-stt = { repo = cfg.stt-model; target = builtins.baseNameOf cfg.stt-model; };
            speaches-tts = { repo = cfg.tts-model; target = builtins.baseNameOf cfg.tts-model; };
        };

        virtualisation.oci-containers.containers.speaches = {
            image = "ghcr.io/speaches-ai/speaches:latest-${if cfg.gpu == null then "cpu" else "cuda" }";
            ports = [ "${toString cfg.port}:8000" ];
            volumes = [
                "${hubSkeleton}:${hubDir}:ro"
                "${stt-hfPath}:${hubDir}/${hubFolder cfg.stt-model}/snapshots/main:ro"
                "${tts-hfPath}:${hubDir}/${hubFolder cfg.tts-model}/snapshots/main:ro"
            ];

            environment = {
                HF_HUB_CACHE = hubDir;
                HF_HUB_OFFLINE = "1";
                
                WHISPER_INFERENCE_DEVICE = "cuda";
                WHISPER_COMPUTE_TYPE = "int8";
                WHISPER__TTL = "-1";

                ENABLE_UI = if cfg.ui then "true" else "false";
                LOG_LEVEL = "info";
            };

            extraOptions = if cfg.gpu != null then [ "--device=nvidia.com/gpu=${gpu}" ] else [];
        };

        networking.firewall.allowedTCPPorts = [ toString cfg.port ];


        systemd.services.docker-speaches = {
            wants = [ "hf-model-speaches-stt.service" "hf-model-speaches-tts.service" ];
            after = [
                "llama-chat.service"
                "hf-model-speaches-stt.service"
                "hf-model-speaches-tts.service"
            ];
            unitConfig.ConditionPathExists = [ stt-hfPath tts-hfPath ];
        };
    };
}
