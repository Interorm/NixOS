{
    config, lib, ...
}: let
    cfg = config.services.docling;
in {
    options.services.docling = {
        enable = lib.mkEnableOption "docling-serve, the document -> Markdown conversion API";

        port = lib.mkOption {
            type = lib.types.port;
            default = 3070;
            description = ''
                Host port the container's 5001 is published on, and the single
                source of truth for the URL: anything that talks to docling
                (the Hermes PDF hook, see services.hermes-agents.doclingPdfHook)
                derives it from here rather than repeating the number.
            '';
        };

        gpu = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "0";
            description = ''
                CDI device index handed to the container, as in
                `--device=nvidia.com/gpu=<gpu>`, and the GPU `DOCLING_DEVICE`
                is pointed at.  null keeps docling on the CPU.

                On this host both GPUs already hold a llama.cpp server, so the
                choice is about which model tolerates a smaller KV cache, not
                which card is free -- see `memoryFraction`.
            '';
        };

        memoryFraction = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "0.24";
            description = ''
                Fraction of the *whole* card PyTorch's caching allocator may
                hand out, via
                `PYTORCH_CUDA_ALLOC_CONF=per_process_memory_fraction:<x>`.
                Only meaningful together with `gpu`.

                This is the hard cap that keeps docling from evicting
                llama.cpp: past it PyTorch raises OOM inside docling instead
                of competing for the last free megabytes.  The CUDA context
                itself (~300 MB) sits OUTSIDE the fraction, so budget

                    fraction x VRAM + 0.3 GB ~= what docling really occupies

                0.24 of an 11 GB 1080 Ti is ~2.7 GB allocator, ~3.0 GB total.

                Requires torch >= 2.10 -- the key did not exist in 2.9 and
                earlier, where it is silently rejected as an unrecognised
                allocator option.  The pinned image below satisfies this.
            '';
        };

        image = lib.mkOption {
            type = lib.types.str;
            default = "quay.io/docling-project/docling-serve-cu126:v1.12.0";
            description = ''
                Container image.  Pinned, and pinned to the *cu126* line, for
                one reason: this host's GPUs are Pascal (GTX 1080 Ti / 1070 Ti,
                sm_61) and upstream PyTorch only ships Maxwell/Pascal cubins in
                its CUDA 12.6 builds.  See pytorch's
                `.ci/manywheel/build_cuda.sh`, where 12.6 alone prepends
                `5.0;6.0` to TORCH_CUDA_ARCH_LIST while the 12.8 and 13.0 cases
                do not.  A cu128/cu130 image starts, loads, and then fails at
                the first kernel launch with "no kernel image is available for
                execution on the device".

                The cu126 repository stops at v1.12.0 (torch 2.10.0+cu126);
                docling-serve v1.31+ publishes only cu128/cu130.  So this tag
                is a dead end by design: it is the newest build that can run on
                these cards at all, and it must not be "updated" to :latest.
                New docling features arrive here only with newer hardware, or
                by moving to `gpu = null`.
            '';
        };

        environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Extra container env vars, merged over the defaults below.";
        };
    };

    config = lib.mkIf cfg.enable {
        virtualisation.oci-containers.containers.docling = {
            image = cfg.image;
            ports = [ "${toString cfg.port}:5001" ];

            environment = {
                DOCLING_SERVE_ENABLE_UI = "true";
                DOCLING_SERVE_ENABLE_REMOTE_SERVICES = "true";

                DOCLING_SERVE_MAX_SYNC_WAIT = "1200";

                # One worker, one shared set of models.  The previous value of
                # 4 with SHARE_MODELS unset is what made this OOM on the GPU:
                # each worker thread allocates its OWN copy of the layout and
                # tableformer models, so "4 workers" meant 4x the VRAM for a
                # box that converts documents one at a time.
                DOCLING_SERVE_ENG_LOC_NUM_WORKERS = "1";
                DOCLING_SERVE_ENG_LOC_SHARE_MODELS = "true";

                UVICORN_WORKERS = "1";
            } // (
                if cfg.gpu != null then {
                    DOCLING_DEVICE = "cuda:0";   # index *within* the container
                    # Pages held in flight at once.  Lower than the default 4
                    # because peak VRAM scales with it and the budget here is
                    # ~3 GB, not a whole card.
                    DOCLING_PERF_PAGE_BATCH_SIZE = "2";
                } else {
                    DOCLING_DEVICE = "cpu";
                    OMP_NUM_THREADS = "4";
                    MKL_NUM_THREADS = "4";
                }
            ) // lib.optionalAttrs (cfg.gpu != null && cfg.memoryFraction != null) {
                PYTORCH_CUDA_ALLOC_CONF = "per_process_memory_fraction:${cfg.memoryFraction}";
            } // cfg.environment;

            # CDI, matching speaches.nix.  Exposing exactly one GPU is also
            # why DOCLING_DEVICE is cuda:0 regardless of `gpu`: the container
            # sees a single device and numbers it from zero.
            extraOptions = lib.optionals (cfg.gpu != null) [
                "--device=nvidia.com/gpu=${cfg.gpu}"
            ];
        };

        # Start after the llama.cpp servers so they claim their VRAM first.
        # Ordering only -- no `wants`, docling is useful on a host where they
        # are absent, and a missing unit here would be a hard dependency
        # failure.  With the allocator fraction set, losing the race would
        # cost docling an OOM rather than cost llama.cpp its cache.
        systemd.services.docker-docling.after = [ "llama-chat.service" "llama-code.service" ];

        networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
}
