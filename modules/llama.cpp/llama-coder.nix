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

    # The constant path, computed by the model module.  This module never spells
    # out a filename: change the quantisation below and everything downstream
    # follows automatically.
    model = config.services.huggingface-models.paths.qwen-coder;
in {
    imports = [ ../huggingface-models.nix ];

    # VERIFY the filename against the repo's file list -- Qwen's GGUF repos
    # sometimes shard large quants into
    # `...-q4_k_m-00001-of-0000N.gguf`, in which case set `file = null` to pull
    # the whole repo and point `target` at the directory instead.
    # A wrong repo/file shows up as a failing `hf-model-qwen-coder.service`
    # in `systemctl --failed`, not as a build error.
    services.huggingface-models.models.qwen-coder = {
        repo = "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF";
        file = "qwen2.5-coder-7b-instruct-q4_k_m.gguf";
        target = "Qwen2.5-Coder-7B-Q4.gguf";
    };

    environment.systemPackages = [ llamacpp-cuda ];

    # The model blobs are far too large for the Nix store and are .gitignored,
    # so they live in mutable state.  This replaces the original
    # `builtins.pathExists ./models/...` guard, which could never work: it runs
    # at *evaluation* time against the read-only copy of the flake in
    # /nix/store, where ./models does not exist.  ConditionPathExists is checked
    # by systemd at *start* time against the real filesystem.
    #
    # (The directory itself is now created by huggingface-models.nix, so the
    # tmpfiles rule that used to live here is gone.)

    systemd.services.llama-code = {
        description = "llama.cpp Server for Coding Completion";
        wantedBy = [ "multi-user.target" ];

        # `wants` not `requires`: if the download fails we still want the unit
        # to be *tried*, at which point ConditionPathExists cleanly skips it.
        # `requires` would drag llama-code into a failed state instead.
        after = [ "network.target" "hf-model-qwen-coder.service" ];
        wants = [ "hf-model-qwen-coder.service" ];

        unitConfig.ConditionPathExists = model;

        serviceConfig = {
            Type = "simple";
            Environment = "CUDA_VISIBLE_DEVICES=1";

            ExecStart = lib.escapeShellArgs [
                "${llamacpp-cuda}/bin/llama-server"
                "--model" model
                "--alias" "Qwen2.5-Coder-7B"
                "--host" "0.0.0.0"
                "--port" "8060"
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

    networking.firewall.allowedTCPPorts = [ 8060 ];
}
