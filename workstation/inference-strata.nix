{
    config, lib, ...
}: {
    imports = [ ../services/inference/strata ];

    services.strata = {
        enable = true;

        # RTX 5090 = Blackwell consumer = compute capability 12.0.
        cuda_architecture = "120";

        instances = {
            "Qwen3.8-Flash-Next" = {
                host = "0.0.0.0";
                port = 8080;
                isDefault = true;
                noApiKey = true;

                model = {
                    repo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
                    # Pinned to the revision upstream's installer pins, so the
                    # SHA-256-verified files are the ones measured.
                    revision = "ed59f92082b1e93c0e96d60a8b11aab089b52f09";
                    shard1 = "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf";
                    shard2 = "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf";
                };

                # 512K: past the trained 262,144, so the module adds
                # `--rope-scaling yarn --rope-scale 2` by itself.  IQ3_XXS's
                # 43 GB of experts + ~6 GB + 512K of streamed KV lands near
                # 56 GB of the 64 GB, which is why this is IQ3_XXS and not
                # IQ3_S (that would need ~63 GB).
                maxContext = 524288;

                # Keep the KV cache in RAM, 32K cells resident in VRAM, so more
                # of the 43 GB of experts fit in the 5090's 32 GB.
                kv = "int8";
                kvResident = 32768;

                # 2 slots to match the concurrency the fleet currently gets
                # from ninfer; the engine serves one request at a time without
                # this.
                parallel = 2;

                # Leave the card usable for other work, and give the VRAM back
                # when the model has been idle for ten minutes.
                vramReserveMib = 1024;
                idleUnloadSeconds = 600;

                arguements = {
                    # Match the model-gateway route name the fleet already uses.
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
