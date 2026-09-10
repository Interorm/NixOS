{
    ...
}: let
    port = 8110;

    gpu = "1";

    dataDir = "/var/lib/speaches";

    sttModel = "deepdml/faster-whisper-large-v3-turbo-ct2";
    ttsModel = "speaches-ai/Kokoro-82M-v1.0-ONNX"; #German: "speaches-ai/piper-de_DE-thorsten-medium";
in {
    systemd.tmpfiles.rules = [
        "d ${dataDir}        0755 root root - -"
        "d ${dataDir}/hf-hub 0755 1000 1000 - -"
    ];

    virtualisation.oci-containers.containers.speaches = {
        image = "ghcr.io/speaches-ai/speaches:latest-cuda";
        ports = [ "${toString port}:8000" ];
        volumes = [ "${dataDir}/hf-hub:/home/ubuntu/.cache/huggingface/hub" ];

        environment = {
            WHISPER__INFERENCE_DEVICE = "cuda";
            WHISPER__COMPUTE_TYPE = "int8";

            PRELOAD_MODELS = builtins.toJSON [ sttModel ttsModel ];
            STT_MODEL_TTL = "-1";
            TTS_MODEL_TTL = "-1";

            ENABLE_UI = "false";
            LOG_LEVEL = "info";
        };

        extraOptions = [ "--device=nvidia.com/gpu=${gpu}" ];
    };

    systemd.services.docker-speaches.after = [ "llama-chat.service" ];
    networking.firewall.allowedTCPPorts = [ port ];
}
