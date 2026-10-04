{
    pkgs, config,
    ...
}: let

    enable_docling = true;

in {

    services.docling = {
        enable = enable_docling;
        gpu = "0";
        memoryFraction = "0.24";
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Qwen3.8-27B";

        dashboardHost = "0.0.0.0";
        dependencyGroups = [ "messaging" "anthropic" ];

        doclingPdfHook.enable = enable_docling;


        mcpServers = { };

        settings = {
            stt = {
                enabled = true;
                provider = "openai";
                language = "";
                openai = {
                    base_url = "http://192.168.42.2:8110/v1";
                    model = "deepdml/faster-whisper-large-v3-turbo-ct2";
                    language = "";
                };
            };
            tts = {
                provider = "openai";
                openai = {
                    api_key = "empty-key";
                    base_url = "http://192.168.42.2:8110/v1";
                    model = "speaches-ai/Kokoro-82M-v1.0-ONNX";
                    voice = "af_heart";
                };
            };

            gateway.multiplex_profiles = true;
        };
    };
}
