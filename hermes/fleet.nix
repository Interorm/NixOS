{
    pkgs, config,
    ...
}: let

    enable_docling = true;

in {
    # Fleet-wide, host-wide settings for the Hermes agent fleet: things that
    # are true of the HOST (which speech backend, which document pipeline),
    # not of any one person.  Per-account identity (soul, ssh keys, ports,
    # profiles) lives in the sibling <name>.nix files; the MCP server fleet
    # lives in ./mcps.nix.  ./default.nix imports all three plus the
    # per-account files into one module.
    services.lean-math = {
        enable = true;
        users = [ "karl" "joni" ];
    };

    services.docling = {
        enable = enable_docling;
        gpu = "0";
        memoryFraction = "0.24";
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Gemma4-E4B";

        dashboardHost = "0.0.0.0";
        dependencyGroups = [ "messaging" "anthropic" ];

        secretsBackend = "agenix";
        doclingPdfHook.enable = enable_docling;

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
        };
    };
}
