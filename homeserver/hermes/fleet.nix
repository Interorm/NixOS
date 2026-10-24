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

        defaultModel = "Qwen3.8-Flash-Next";

        dashboard.host = "0.0.0.0";

        dependencyGroups = [ "messaging" "anthropic" ];
        extraPackages = [ pkgs.chromium pkgs.agent-browser ];
        docling.enable = enable_docling;


        mcpServers = { };

        settings = {
            model_overrides.custom = {
                "Qwen3.8-27B".context_window = 240000;
                "Qwen3.8-Flash-Next".context_window = 390000;
            };

            compression = {
                enabled = true;
                threshold = 0.8;

                tail_mode = "lean";
                target_ratio = 0.33;
            };

            auxiliary = {
                approval = {
                    provider = "custom";
                    model = "Gemma4-E4B";
                    base_url = "http://127.0.0.1:8080/v1";
                    api_key = "\${OPENAI_API_KEY}";
                };
                title_generation = {
                    provider = "custom";
                    model = "Gemma4-E4B";
                    base_url = "http://127.0.0.1:8080/v1";
                    api_key = "\${OPENAI_API_KEY}";
                };
                vision = {
                    provider = "custom";
                    model = "Gemma4-E4B";
                    base_url = "http://127.0.0.1:8080/v1";
                    api_key = "\${OPENAI_API_KEY}";
                };
            };

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
