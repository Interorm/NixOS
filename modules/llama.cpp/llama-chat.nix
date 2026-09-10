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

    model  = config.services.huggingface-models.paths.qwen-chat;
    mmproj = config.services.huggingface-models.paths.qwen-chat-mmproj;
    mtp    = config.services.huggingface-models.paths.qwen-chat-mtp;
in {
    imports = [ ./huggingface-models.nix ];

    services.huggingface-models.models.qwen-chat = {
        repo = "unsloth/gemma-4-E4B-it-qat-GGUF";
        file = "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf";
        target = "Gemma4-E4B-Q4.gguf";
    };

    services.huggingface-models.models.qwen-chat-mmproj = {
        repo = "unsloth/gemma-4-E4B-it-qat-GGUF";
        file = "mmproj-F16.gguf";
        target = "Gemma4-E4B-mmproj-F16.gguf";
    };

    # MTP drafter for `--spec-type draft-mtp`.  Also a separate GGUF; llama.cpp
    # only auto-discovers it with `-hf`, with `--model` it has to be passed as
    # `--model-draft` or the server dies with "model doesn't contain MTP
    # layers".  Root file is the smart Q4_0 unsloth recommends; MTP/ holds
    # Q8_0/F16/BF16 if you want to compare acceptance rates.
    services.huggingface-models.models.qwen-chat-mtp = {
        repo = "unsloth/gemma-4-E4B-it-qat-GGUF";
        file = "mtp-gemma-4-E4B-it.gguf";
        target = "Gemma4-E4B-mtp-Q4_0.gguf";
    };

    environment.systemPackages = [ llamacpp-cuda ];

    # Renamed from `llama-code` to `llama-chat`: this module and llama-coder.nix
    # both defined `systemd.services.llama-code`, so importing both meant one
    # silently clobbered the other.
    systemd.services.llama-chat = {
        description = "llama.cpp Server for normal Chat model";
        wantedBy = [ "multi-user.target" ];
        after = [
            "network.target"
            "hf-model-qwen-chat.service"
            "hf-model-qwen-chat-mmproj.service"
            "hf-model-qwen-chat-mtp.service"
        ];
        wants = [
            "hf-model-qwen-chat.service"
            "hf-model-qwen-chat-mmproj.service"
            "hf-model-qwen-chat-mtp.service"
        ];

        unitConfig.ConditionPathExists = [ model mmproj mtp ];

        serviceConfig = {
            Type = "simple";
            Environment = "CUDA_VISIBLE_DEVICES=0";

            ExecStart = lib.escapeShellArgs [
                "${llamacpp-cuda}/bin/llama-server"
                "--model" model
                "--mmproj" mmproj
                "--model-draft" mtp
                "--jinja"
                "--alias" "Gemma4-E4B"
                "--host" "0.0.0.0"
                "--port" "8070"
                "--n-gpu-layers" "999"
                "--parallel" "4"
                "--ctx-size" "127000"
                "--ctx-checkpoints" "4"
                "--cache-type-k" "q8_0"
                "--spec-type" "draft-mtp"
                "--spec-draft-n-max" "4"
                "--flash-attn" "off"
            ];

            Restart = "always";
            RestartSec = "5";
        };
    };

    networking.firewall.allowedTCPPorts = [ 8070 ];
}
