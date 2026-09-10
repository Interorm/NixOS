{
    pkgs, config, lib,
    ...
}: let
    cudaPackages = pkgs.cudaPackages_13_2;

    ninfer = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "ninfer";
        version = "unstable-2026-09-08";

        src = pkgs.fetchFromGitHub {
            owner = "Neroued";
            repo = "ninfer";

            # PLACEHOLDER.  Pin an actual commit, then let Nix tell you the hash:
            #   nix-prefetch-github Neroued ninfer --rev <sha>
            # or leave lib.fakeHash in place, run the build, and copy the
            # "got: sha256-..." from the error.  That trial-and-error loop is
            # the normal Nix workflow, not a mistake.
            rev = "641ef3e7af08fe8f58b769e9f7505f642975a9dc";
            hash = "sha256-RsGsaB93lezcebwYQT6cq4iL7PteRuY2/40OJ98H1CU=";
        };

        nativeBuildInputs = with pkgs; [
            cmake        # >= 3.28 required
            ninja        # upstream builds with -G Ninja
            pkg-config
            cudaPackages.cuda_nvcc

            # Patches DT_RUNPATH so the resulting binaries can find libcuda.so
            # from the *driver* at runtime.  libcuda.so is not in the store --
            # it comes from the running kernel module -- so without this hook
            # every CUDA binary built in the sandbox fails with
            # "libcuda.so.1: cannot open shared object file".
            autoAddDriverRunpath
        ];

        buildInputs = with pkgs; [
            curl         # libcurl >= 7.85, for hub downloads
            ffmpeg       # libavformat>=60 libavcodec>=60 libavutil>=58 libswscale>=7
        ] ++ (with cudaPackages; [
            cuda_cudart
            cccl
            libcublas
            cuda_nvtx
        ]);

        cmakeFlags = [
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_CUDA_ARCHITECTURES=120a"
        ];

        # Upstream ships no `install` target, so the generic installPhase would
        # produce an empty $out.  cwd here is the cmake build dir.
        installPhase = ''
            runHook preInstall
            install -Dm755 apps/ninfer       "$out/bin/ninfer"
            install -Dm755 apps/ninfer-serve "$out/bin/ninfer-serve"
            runHook postInstall
        '';

        meta = {
            description = "From-scratch single-GPU CUDA inference engine";
            homepage = "https://github.com/Neroued/ninfer";
            license = lib.licenses.asl20;
            platforms = [ "x86_64-linux" ];
        };
    });

    model = config.services.huggingface-models.paths.qwen3-8-27b;

    # Remote control surface for the homeserver's llama-proxy.  The proxy SSHes
    # in and runs `sudo ninferctl <verb>`; everything it is allowed to do is
    # enumerated here, so the sudo rule below can be a single NOPASSWD entry on
    # one binary instead of blanket root.
    ninferctl = pkgs.writeShellScriptBin "ninferctl" ''
        set -euo pipefail
        case "''${1:-}" in
            start)    exec systemctl start    ninfer-serve.service ;;
            stop)     exec systemctl stop     ninfer-serve.service ;;
            restart)  exec systemctl restart  ninfer-serve.service ;;
            status)   exec systemctl is-active ninfer-serve.service ;;
            poweroff) exec systemctl poweroff ;;
            *) echo "usage: ninferctl {start|stop|restart|status|poweroff}" >&2; exit 2 ;;
        esac
    '';
in {
    imports = [ ./huggingface-models.nix ];

    services.huggingface-models.models.qwen3-8-27b = {
        # nvfp4 weights: ~4-bit, fits the 5090's 32 GB with room for a large KV
        # cache.  The unquantised `neroued/Qwen3.8-27B-NInfer` will not.
        repo = "neroued/Qwen3.8-27B-nvfp4-NInfer";
        file = "qwen3_8_27b_nvfp4.ninfer";
        target = "Qwen3.8-27B-nvfp4.ninfer";
    };

    environment.systemPackages = [ ninfer ninferctl ];

    systemd.services.ninfer-serve = {
        description = "NInfer inference server (Qwen3.8-27B, nvfp4)";

        # Deliberately NOT `wantedBy = [ "multi-user.target" ]`.  The whole point
        # of the proxy is that this box sleeps until someone actually asks for a
        # token; autostarting would pin ~30 GB of VRAM and the GPU's idle draw
        # around the clock.  The proxy starts it over SSH.
        after = [ "network.target" "hf-model-qwen3-8-27b.service" ];
        wants = [ "hf-model-qwen3-8-27b.service" ];

        unitConfig.ConditionPathExists = model;

        serviceConfig = {
            Type = "simple";

            ExecStart = lib.escapeShellArgs [
                "${ninfer}/bin/ninfer-serve"
                model
                "--model-id" "Qwen3.8-27B"

                "--host" "0.0.0.0"
                "--port" "8080"

                "--max-context" "240000"
                "--kv-capacity" "auto"
                "--kv-dtype" "fp8"

                "--max-concurrency" "2"

                "--device-state-slots" "2"
                "--host-state-slots" "8"
                "--host-kv-mib" "16384"

                "--spec" "mtp"
                "--draft-tokens" "3"
                "--lm-head-draft"

                "--preserve-thinking"

                "--vision"
            ];

            TimeoutStartSec = "600";

            Restart = "on-failure";
            RestartSec = "10";
        };
    };

    networking.firewall.allowedTCPPorts = [ 8080 ];
    networking.interfaces."enp6s0".wakeOnLan.enable = true;

    security.sudo.extraRules = [{
        users = [ "karl" ];
        commands = [{
            command = "/run/current-system/sw/bin/ninferctl";
            options = [ "NOPASSWD" ];
        }];
    }];

    services.openssh = {
        enable = true;
    };
    users.users."karl".openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPootR7FogHsp0OdnDu6kjPj2rqHribx0OnFvzyfnYGY root@homeserver"
    ];
}
