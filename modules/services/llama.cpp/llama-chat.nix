{
    pkgs, config, lib,
    ...
}: let
    llamacpp-cuda = (pkgs.llama-cpp.override {
        cudaSupport = true;
    }).overrideAttrs (oldAttrs: {
        cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
            "-DGGML_CUDA=ON"
            "-DGGML_CUDA_F16=OFF"
            "-DCMAKE_CUDA_ARCHITECTURES=61"   # Pascal: GTX 1080 / 1070 Ti
        ];
    });

    model = config.services.huggingface-models.paths.qwen-chat;
in {
    imports = [ ../huggingface-models.nix ];

    # PLACEHOLDER COORDINATES -- I have not verified that this repo/file pair
    # exists, and I am not going to guess a repo id into your config and let you
    # find out at 3 a.m.  Look up the actual repo on huggingface.co, copy the
    # exact filename from its "Files" tab, and replace both fields.  `target`
    # can stay as-is; that is the whole point of decoupling it.
    services.huggingface-models.models.qwen-chat = {
        repo = "unsloth/Qwen3.5-9B-GGUF";
        file = "Qwen3.5-9B-UD-Q6_K_XL.gguf";
        target = "Qwen3.5-9B-Q6.gguf";
    };

    environment.systemPackages = [ llamacpp-cuda ];

    # Renamed from `llama-code` to `llama-chat`: this module and llama-coder.nix
    # both defined `systemd.services.llama-code`, so importing both meant one
    # silently clobbered the other.
    systemd.services.llama-chat = {
        description = "llama.cpp Server for normal Chat model";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "hf-model-qwen-chat.service" ];
        wants = [ "hf-model-qwen-chat.service" ];

        unitConfig.ConditionPathExists = model;

        serviceConfig = {
            Type = "simple";
            Environment = "CUDA_VISIBLE_DEVICES=0";

            ExecStart = lib.escapeShellArgs [
                "${llamacpp-cuda}/bin/llama-server"
                "--model" model
                "--alias" "Qwen3.5-9B"
                "--host" "0.0.0.0"
                "--port" "8070"
                "--n-gpu-layers" "999"
                "--parallel" "4"
                "--ctx-checkpoints" "4"
                "--flash-attn" "on"
            ];

            Restart = "always";
            RestartSec = "5";
        };
    };

    networking.firewall.allowedTCPPorts = [ 8070 ];
}
