{
    pkgs, lib,
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

    modelDir = "/var/lib/llama/models";
    model = "${modelDir}/Qwen3.5-9B-Q6.gguf";
in {
    environment.systemPackages = [ llamacpp-cuda ];

    systemd.tmpfiles.rules = [
        "d ${modelDir} 0755 root root - -"
    ];

    # Renamed from `llama-code` to `llama-chat`: this module and llama-coder.nix
    # both defined `systemd.services.llama-code`, so importing both meant one
    # silently clobbered the other.
    systemd.services.llama-chat = {
        description = "llama.cpp Server for normal Chat model";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

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
}
