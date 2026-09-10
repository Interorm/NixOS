{
    ...
}: {

    systemd.services.init-openwebui-net = {
        requiredBy = [ "docker-playwright.service" ];
        before = [ "docker-playwright.service" ];
    };

    virtualisation.oci-containers.containers.playwright = {
        image = "mcr.microsoft.com/playwright:v1.58.0-noble";

        ports = [ "3035:3035" ];

        cmd = [
            "npx" "-y" "playwright@1.58.0"
            "run-server"
            "--port" "3035"
            "--host" "0.0.0.0"
        ];

        extraOptions = [
            "--network=OpenWebUI_net"
            # "--shm-size=1g"
        ];
    };

    networking.firewall.allowedTCPPorts = [ 3035 ];
}
