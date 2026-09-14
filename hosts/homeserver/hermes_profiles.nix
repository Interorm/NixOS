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

            # Sabine (Karl's mother): Home Assistant control/status only, for
            # now.  No SSH login key of her own yet -- she has no keypair, so
            # this account is intentionally login-locked (sshKeys stays
            # empty) and her agenix secret is encrypted to Karl's key
            # instead of her own (see secrets/secrets.nix override).  She
            # reaches the agent purely through the dashboard/PWA over
            # Tailscale; Karl manages the account and its secret on her
            # behalf until she has her own SSH key, at which point add it
            # here and re-key her secret to her instead.
            sabine = {
                dashboard.port = 9070;
                mobile.enable = true;

                sshKeys = [ ];

                soul = ''
                    You are Sabine's personal assistant. Be warm, simple and
                    patient -- explain things in plain language, avoid
                    jargon, and confirm before taking any action.
                    Right now your only job is Home Assistant: report the
                    state of her smart home devices and control them
                    (lights, heating, locks, etc.) when she asks.
                    Always double check what you are about to change before
                    doing it, and tell her plainly what happened afterwards.
                '';

                mcpServers = {
                    # Home Assistant's built-in MCP Server integration,
                    # reached over her Tailscale network (not the public
                    # internet, no port forwarding).  HA_URL and HA_TOKEN
                    # come from her agent's secret file -- see
                    # secrets/hermes-sabine.age.  The /api/mcp/assist path
                    # exposes exactly the entities she has chosen to expose
                    # on HA's "Voice assistants -> Expose" page.
                    home-assistant = {
                        url = "\${HA_URL}/api/mcp/assist";
                        headers.Authorization = "Bearer \${HA_TOKEN}";
                    };
                };
            };
        };
    };
}
