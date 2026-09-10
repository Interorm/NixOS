{
    ...
}: {
    services.model-gateway = {
        enable = true;

        host = "0.0.0.0";
        port = 8080;

        endpoints = {
            coder = { url = "http://localhost:8060"; };
            chat  = { url = "http://localhost:8070"; };

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