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
    model = "${modelDir}/Qwen2.5-Coder-7B-Q4.gguf";
in {
    environment.systemPackages = [ llamacpp-cuda ];

    # The model blobs are far too large for the Nix store and are .gitignored,
    # so they live in mutable state.  This replaces the original
    # `builtins.pathExists ./models/...` guard, which could never work: it runs
    # at *evaluation* time against the read-only copy of the flake in
    # /nix/store, where ./models does not exist.  ConditionPathExists is checked
    # by systemd at *start* time against the real filesystem.
    systemd.tmpfiles.rules = [
        "d ${modelDir} 0755 root root - -"
    ];

    systemd.services.llama-code = {
        description = "llama.cpp Server for Coding Completion";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        unitConfig.ConditionPathExists = model;

        serviceConfig = {
            Type = "simple";
            Environment = "CUDA_VISIBLE_DEVICES=1";

            ExecStart = lib.escapeShellArgs [
                "${llamacpp-cuda}/bin/llama-server"
                "--model" model
                "--alias" "Qwen2.5-Coder-7B"
                "--host" "0.0.0.0"
                "--port" "8080"
                "--n-gpu-layers" "999"
                "--parallel" "4"
                "--ctx-size" "32768"
                "--cache-reuse" "256"
                "--ctx-checkpoints" "4"
                "--flash-attn" "on"
            ];

            Restart = "always";
            RestartSec = "5";
        };
    };
}
