{
    config, lib, pkgs,
    ...
}: let
    port = 8110;

    gpu = "1";

    sttModel = "deepdml/faster-whisper-large-v3-turbo-ct2";
    ttsModel = "speaches-ai/Kokoro-82M-v1.0-ONNX"; #German: "speaches-ai/piper-de_DE-thorsten-medium";

    stt = config.services.huggingface-models.paths.speaches-stt;
    tts = config.services.huggingface-models.paths.speaches-tts;

    # Speaches resolves a repo id against a HF hub cache
    # ($HF_HUB_CACHE/models--<org>--<name>/{refs/main,snapshots/<ref>/...}),
    # so the downloaded directories are mounted into this fixed skeleton.
    hubDir    = "/hf-hub";
    hubFolder = repo: "models--${lib.replaceStrings [ "/" ] [ "--" ] repo}";
    hubSkeleton = pkgs.runCommand "speaches-hf-hub" {} (lib.concatMapStrings (repo: ''
        mkdir -p $out/${hubFolder repo}/refs $out/${hubFolder repo}/snapshots/main
        printf main > $out/${hubFolder repo}/refs/main
    '') [ sttModel ttsModel ]);
in {
    imports = [ ../../llama.cpp/huggingface-models.nix ];

    services.huggingface-models.models = {
        speaches-stt = { repo = sttModel; target = "faster-whisper-large-v3-turbo-ct2"; };
        speaches-tts = { repo = ttsModel; target = "Kokoro-82M-v1.0-ONNX"; };
    };

    virtualisation.oci-containers.containers.speaches = {
        image = "ghcr.io/speaches-ai/speaches:latest-cuda";
        ports = [ "${toString port}:8000" ];
        volumes = [
            "${hubSkeleton}:${hubDir}:ro"
            "${stt}:${hubDir}/${hubFolder sttModel}/snapshots/main:ro"
            "${tts}:${hubDir}/${hubFolder ttsModel}/snapshots/main:ro"
        ];

        environment = {
            HF_HUB_CACHE = hubDir;
            HF_HUB_OFFLINE = "1";

            WHISPER__INFERENCE_DEVICE = "cuda";
            WHISPER__COMPUTE_TYPE = "int8";
            WHISPER__TTL = "-1";

            ENABLE_UI = "false";
            LOG_LEVEL = "info";
        };

        extraOptions = [ "--device=nvidia.com/gpu=${gpu}" ];
    };

    systemd.services.docker-speaches = {
        wants = [ "hf-model-speaches-stt.service" "hf-model-speaches-tts.service" ];
        after = [
            "llama-chat.service"
            "hf-model-speaches-stt.service"
            "hf-model-speaches-tts.service"
        ];
        unitConfig.ConditionPathExists = [ stt tts ];
    };

    networking.firewall.allowedTCPPorts = [ port ];
}
