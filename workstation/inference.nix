{
    config, lib, ...
}: {
    imports = [ 
        ../services/inference/dnd-toggle.nix
        ../services/inference/ninfer 
        ../services/inference/strata
        ../services/inference/model-gateway
    ];

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

    services.strata = {
        enable = true;

        cuda_architecture = "120";

        instances = {
            "Qwen3.8-Flash-Next" = {
                host = "0.0.0.0";
                port = 8090;
                isDefault = true;
                noApiKey = true;

                model = {
                    repo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
                    revision = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
                    shards = [
                        "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf"
                        "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf"
                    ];
                    pleIdx = 2;
                    expertProfile = "expert-profile.bin";
                };

                maxContext = 390000;
                scaling.enable = true;
                scaling.factor = 1.5;
                parallel = 2;

                arguements = {
                    kv = "int8";
                    kv-resident = 32768;
                };
            };
        };
    };

    services.model-gateway = {
        enable = true;
        host = "0.0.0.0";
        port = 8000;
    };

    networking.interfaces."enp6s0".wakeOnLan.enable = true;

    services.openssh = { enable = true; };

    users.users."karl".openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPootR7FogHsp0OdnDu6kjPj2rqHribx0OnFvzyfnYGY root@homeserver"
    ];
} 