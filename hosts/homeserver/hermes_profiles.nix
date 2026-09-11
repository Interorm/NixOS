{
    pkgs, config,
    ...
}: {
    services.lean-math = {
        enable = true;
        users = [ "karl" "joni" ];
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Gemma4-E4B";

        dashboardHost = "192.168.42.2";
        dependencyGroups = [ "messaging" "anthropic" ];

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
                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
                ];
                extraPackages = [ pkgs.elan ];
                soul = ''
                    You are Karl's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.  
                    Voice messages reach you already transcribed; answer in the language the user used.
                    You have access to a nix environment, so you can run nix commands. 
                    You also have access to lean4 in your environment.
                '';
            };
            joni = {
                dashboard.port = 9080;
                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop"
                ];
                extraPackages = [ pkgs.elan ];
                soul = ''
                    You are Joni's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.  
                    Voice messages reach you already transcribed; answer in the language the user used.
                    You have access to a nix environment, so you can run nix commands. 
                    You also have access to lean4 in your environment.

                '';
            };
        };
    };
}
