{
    pkgs, config, lib,
    ...
}: let

    enable_docling = true;

    stt = "deepdml/faster-whisper-large-v3-turbo-ct2";
    tts = "speaches-ai/Kokoro-82M-v1.0-ONNX";

in {

    services.docling = {
        enable = enable_docling;
        gpu = "0";
        memoryFraction = "0.24";
    };

    services.speaches = lib.mkIf ((stt != null) || (tts != null)) {
        enable = true;
        gpu = "1";

        port = 8110;
        ui = false;

        stt-model = stt;
        tts-model = tts;
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Qwen3.8-27B";

        dashboard.host = "0.0.0.0";

        dependencyGroups = [ "messaging" "anthropic" ];
        extraPackages = [ pkgs.chromium ];
        docling.enable = enable_docling;


        mcpServers = { };

        settings = {
            stt = {
                enabled = true;
                provider = "openai";
                language = "";
                openai = {
                    api_key = "empty-key";
                    base_url = "http://localhost:${toString config.services.speaches.port}/v1";
                    model = stt;
                    language = "";
                };
            };
            tts = {
                provider = "openai";
                openai = {
                    api_key = "empty-key";
                    base_url = "http://localhost:${toString config.services.speaches.port}/v1";
                    model = tts;
                    voice = "af_heart";
                };
            };

            gateway.multiplex_profiles = true;
        };
    };
}
