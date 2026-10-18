{
    config, lib, ...
}: {
    imports = [ ../services/inference/ninfer ];

    services.ninfer = {
        enable = true;

        instances = {
            "Qwen3.8-27B" = {
                host = "0.0.0.0";
                port = 8080;
                model = {
                    repo = "neroued/Qwen3.8-27B-nvfp4-NInfer";
                    file = "qwen3_8_27b_nvfp4.ninfer";
                };
                arguements = {
                    max-context = 240000;
                    kv-capacity = "auto";
                    kv-dtype = "nvfp4";
                    no-cuda-graph = true;

                    max-concurrency = 2;
                    device-state-slots = 2;
                    host-state-slots = 8;
                    host-kv-mib = 16384;

                    spec = "mtp";
                    draft-tokens = 3;
                    lm-head-draft = true;

                    preserve-thinking = true;
                    vision = true;
                };
            }; 
        };
    };

    networking.interfaces."enp6s0".wakeOnLan.enable = true;

    services.openssh = { enable = true; };

    users.users."karl".openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPootR7FogHsp0OdnDu6kjPj2rqHribx0OnFvzyfnYGY root@homeserver"
    ];
} 