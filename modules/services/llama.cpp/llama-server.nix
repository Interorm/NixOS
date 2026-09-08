{
    pkgs, config,
    ...
}: let
    llamacpp-cuda = (pkgs.llama-cpp.override {
        cudaSupport = true;
    }).overrideAttrs (oldAttrs: {
        cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
            "-DGGML_CUDA=ON"
            "-DGGML_CUDA_F16=OFF"
            "-DCMAKE_CUDA_ARCHITECTURES=61"
        ];
    });

    hf-downloader = pkgs.python313Packages.python.withPackages (ps: [
        ps.huggingface-hub
    ]);

in {
    
    if !(builtins.pathExists ./models/Qwen3.5-9B-Q6.gguf) then
        

    environment.systemPackages = with pkgs; [ llamacpp-cuda ];

    systemd.services.llama-code = {
        description = "llama.cpp Server for Coding Completion";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
            Type = "simple";
            Environment = "CUDA_VISIBLE_DEVICES=1";

            ExecStart = pkgs.lib.escapeShellArgs [
                "${llamacpp-cuda}/bin/llama-server"
                "--model" "./models/Qwen3.5-9B-Q6.gguf"
                "--alias" "\"Qwen3.5-9B\""
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