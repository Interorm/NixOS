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
                    You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.
                    The following packages are avaible: python314, uv, npm, nodejs, elan (lean4), aswell as standard read/write utilities.
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
                    You are Joni's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.  
                    Voice messages reach you already transcribed; answer in the language the user used.
                    You have access to a nix environment, so you can run nix commands. 
                    You also have access to lean4 in your environment.

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

                    You have two Home Assistant MCPs:
                    - home-assistant-fullaccess: your main workbench. Use
                      it for EVERYTHING -- reading states, controlling
                      devices, and creating, editing or deleting
                      automations, scripts, scenes and helpers. It exposes
                      many tools; look up the right one (e.g. search for
                      the tool) instead of guessing, and when Sabine asks
                      for a new routine, create it for her -- do not ask
                      her to build it herself.
                    - home-assistant-controls: a limited fallback that can
                      only read her exposed entities and turn them on/off.
                      Use it ONLY when fullaccess is unreachable or errors. Report those errors.

                    Always double check what you are about to change
                    (read the current state first), verify afterwards that
                    the change actually took effect, and tell her plainly
                    what happened.

                '';

                mcpServers = {
                    # Home Assistant's built-in MCP Server integration,
                    # reached over her Tailscale network (not the public
                    # internet, no port forwarding).  HA_URL and HA_TOKEN
                    # come from her agent's secret file -- see
                    # secrets/hermes-sabine.age.  The /api/mcp/assist path
                    # exposes exactly the entities she has chosen to expose
                    # on HA's "Voice assistants -> Expose" page.
                    home-assistant-controls = {
                        url = "\${HA_URL}/api/mcp/assist";
                        headers.Authorization = "Bearer \${HA_TOKEN}";
                    };

                    home-assistant-fullaccess = {
                        url = "\${HA_URL_FULLACCESS}";
                    };
            };
        };
    };
}
