{
    ...
}: {

    imports = [ 
        ../services/inference/llama-cpp 
        ../services/inference/model-gateway
        ../services/inference/proxy 
    ];

    services.llama-cpp = {
        cuda = true;
        cuda_architecture = 61;
        modelGateway = true;

        instances = {

            Gemma4-E4B = {
                port = 8070;

                model = {
                    repo = "unsloth/gemma-4-E4B-it-qat-GGUF";
                    file = "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf";
                    mtp = "mtp-gemma-4-E4B-it.gguf";
                    mmproj = "mmproj-F16.gguf";
                };

                device = 0;
                arguements = {
                    n-gpu-layers = "999";
                    flash-attn = "off";

                    spec-type = "draft-mtp";
                    spec-draft-n-max = 4;

                    parallel = 4;
                    kv-unified = true;

                    ctx-size = 100000;
                    ctx-checkpoints = 4;
                    cache-type-k = "q8_0";
                };
            };

            "Qwen2.5-Coder-7B" = {
                port = 8060;

                model = {
                    repo = "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF";
                    file = "qwen2.5-coder-7b-instruct-q4_k_m.gguf";
                };

                device = 0;
                arguements = {
                    n-gpu-layers = "999";
                    flash-attn = "on";

                    parallel = 4;
                    cache-reuse = 256;

                    ctx-size = 32768;
                    ctx-checkpoints = 4;
                    cache-type-k = "q8_0";
                    cache-type-v = "q8_0";
                };
            };

        };
    };


    services.model-gateway = {
        enable = true;

        host = "0.0.0.0";
        port = 8080;

        endpoints = {
            pc = {
                url = "http://localhost:8090";
                discovery = "static";
                models = [ "Qwen3.8-27B" ]; 
                healthPath = "/proxy/status";
                timeout = 1200.0;
            };
        };
    };
}