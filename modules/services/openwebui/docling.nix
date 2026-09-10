{
    ...
}: {

    systemd.services.init-openwebui-net = {
        requiredBy = ["docker-docling.service"];
        before = ["docker-docling.service"];
    };

    virtualisation.oci-containers.containers = {
        docling = {
            image = "quay.io/docling-project/docling-serve:latest";
            ports = [ "3070:5001" ];

            environment = {
                DOCLING_SERVE_ENABLE_UI = "true";
                DOCLING_SERVE_ENABLE_REMOTE_SERVICES = "true";

                DOCLING_SERVE_MAX_SYNC_WAIT = "1200";
                DOCLING_SERVE_ENG_LOC_NUM_WORKERS = "4";

                OMP_NUM_THREADS = "4";
                MKL_NUM_THREADS = "4";

                UVICORN_WORKERS = "1";
                # CUDA_VISIBLE_DEVICES="1"; 
            };

            extraOptions = [
                "--network=OpenWebUI_net"
                # "--gpus" "all"
                # "--device" "nvidia.com/gpu=all"
            ];
        };
    };

    networking.firewall.allowedTCPPorts = [ 3070 ];
}