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
            description = "Port for docling service";
        };

        gpu = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "0";
            description = "GPU device index. null indecates CPU-only";
        };

        memoryFraction = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "0.24";
            description = "Fraction of card VRAM docling is allowed to allocate. Set via pytorch environment variable.";
        };

        image = lib.mkOption {
            type = lib.types.str;
            default = "quay.io/docling-project/docling-serve-cu126:v1.12.0";
            description = "Image to be used for the docling container. This has to be modified to account for different CUDA versions or the CPU-only version";
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

                DOCLING_SERVE_ENG_LOC_NUM_WORKERS = "1";
                DOCLING_SERVE_ENG_LOC_SHARE_MODELS = "true";

                UVICORN_WORKERS = "1";
            } 
            // (if cfg.gpu != null then {
                    DOCLING_DEVICE = "cuda:0";   
                    DOCLING_PERF_PAGE_BATCH_SIZE = "2";
                } else {
                    DOCLING_DEVICE = "cpu";
                    OMP_NUM_THREADS = "4";
                    MKL_NUM_THREADS = "4";
                })
            // lib.optionalAttrs (cfg.gpu != null && cfg.memoryFraction != null) {
                PYTORCH_CUDA_ALLOC_CONF = "per_process_memory_fraction:${cfg.memoryFraction}";
            } // cfg.environment;

            extraOptions = lib.optionals (cfg.gpu != null) [
                "--device=nvidia.com/gpu=${cfg.gpu}"
            ];
        };

        networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
}
