{
    ...
}: let
    hostGateway = "host.docker.internal";
    dataDir = "/var/lib/openwebui";
in {

    systemd.services.init-openwebui-net = {
        requiredBy = [
            "docker-openwebui.service"
            "docker-open-terminal.service"
        ];
        before = [
            "docker-openwebui.service"
            "docker-open-terminal.service"
        ];
    };

    systemd.tmpfiles.rules = [
        "d ${dataDir}          0755 root root - -"
        "d ${dataDir}/data     0755 root root - -"
        "d ${dataDir}/terminal 0755 root root - -"
    ];

    virtualisation.oci-containers.containers = {
        openwebui = {
            image = "ghcr.io/open-webui/open-webui:main";
            ports = [ "3000:8080" ];
            environment = {
                WEBUI_SECRET_KEY = "empty-key";

                OPENAI_API_BASE = "http://${hostGateway}:8080";
                OPENAI_API_KEY = "empty-key";

                ENABLE_WEB_SEARCH = "true";
                WEB_SEARCH_ENGINE = "searxng";
                SEARXNG_QUERY_URL = "http://searxng:3030/search?q=<query>&format=json";

                WEB_SEARCH_RESULT_COUNT = "10";
                WEB_SEARCH_CONCURRENT_REQUESTS = "3";

                WEB_LOADER_ENGINE = "playwright";
                PLAYWRIGHT_WS_URL = "ws://playwright:3035";
            };

            volumes = [ "${dataDir}/data:/app/backend/data" ];
            dependsOn = [ "mcpo" "open-terminal" ];

            extraOptions = [
                "--network=OpenWebUI_net"
                "--add-host=host.docker.internal:host-gateway"
            ];
        };

        open-terminal = {
            image = "ghcr.io/open-webui/open-terminal";
            environment.OPEN_TERMINAL_API_KEY = "empty-key";
            volumes = [ "${dataDir}/terminal:/home/user" ];
            extraOptions = [
                "--network=OpenWebUI_net"
                "--network-alias=openterminal"
            ];
        };
    };

    networking.firewall.allowedTCPPorts = [ 3000 ];
}
