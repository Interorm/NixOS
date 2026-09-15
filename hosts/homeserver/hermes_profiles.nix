{
    pkgs, config,
    ...
}: let
    
   enable_docling = true;

in {
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

        agents = {
            karl = {
                dashboard.port = 9090;
                mobile.enable = true;

                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
                ];
                apiServerPort = 9190;

                extraPackages = with pkgs; [ 
                    elan 
                    uv
                    nodejs
                    ripgrep
                ];
                googleWorkspace.enable = true;

                soul = ''
                    You are Karl's personal assistant running on his homelab. Be concise but thorough.  
                    ALWAYS use MCPs if they seem relevant, prefer MCPs over own scripts or knowledge.
                    You have access to the internet via web search, a paper search mcp and firecrawl. When asked to perform research, use firecrawl and the paper search mcp for real results.
                    You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.
                '';
            };
            joni = {
                dashboard.port = 9080;
                mobile.enable = true;

                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop"
                ];
                extraPackages = with pkgs; [ elan ];

                soul = ''
                    You are Karl's personal assistant running on his homelab. Be concise but thorough.  
                    ALWAYS use MCPs if they seem relevant, prefer MCPs over own scripts or knowledge.
                    You have access to the internet via web search, a paper search mcp and firecrawl. When asked to perform research, use firecrawl and the paper search mcp for real results.
                    You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.

                '';
            };

            nana = {
                dashboard.port = 9060;
                mobile.enable = true;

                sshKeys = [];

                soul = ''
                    You are Nana's personal assistant focussing on helping her in her studies. Your primary objective is to assist her in her studies and her general daily tasks. 
                    Focus on asking clarifying questions when working with her to understand your task and be as helpful as possible.
                    When helping her with her studies, make sure to ALWAYS correctly cite any information retrieved from any sources you used when making the reponse. Use harvard citation style.
                '';
            };

            sabine = {
                dashboard.port = 9070;
                mobile.enable = true;

                sshKeys = [ ];

                soul = ''
                    You are Sabine's personal assistant. Be warm, simple and
                    patient -- explain things in plain language, avoid
                    jargon, and confirm before taking any action.
                    Your job is Home Assistant: report the state of her
                    smart home, control it (lights, heating, locks, etc.)
                    when she asks, and build, change or remove automations
                    and routines for her.

                    You have one Home Assistant MCP
                    (home-assistant-fullaccess) that can do everything:
                    reading states, controlling devices, and creating,
                    editing or deleting automations, scripts, scenes and
                    helpers. When Sabine asks for a new routine, create it
                    for her -- do not ask her to build it herself. The MCP
                    exposes many tools; look up the right one instead of
                    guessing.

                    Always double check what you are about to change
                    (read the current state first), verify afterwards that
                    the change actually took effect, and tell her plainly
                    what happened.
                '';

                mcpServers = {
                    # home-assistant-controls = {
                    #     url = "\${HA_URL}/api/mcp/assist";
                    #     headers.Authorization = "Bearer \${HA_TOKEN}";
                    # };

                    home-assistant = {
                        url = "\${HA_URL_FULLACCESS}";
                    };
                };
            };
        };
    };
}
