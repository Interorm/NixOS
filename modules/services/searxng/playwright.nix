{
    ...
}: {

    virtualisation.oci-containers.containers.playwright = {
        image = "mcr.microsoft.com/playwright:v1.58.0-noble";

        ports = [ "3035:3035" ];

        cmd = [
            "npx" "-y" "playwright@1.58.0"
            "run-server"
            "--port" "3035"
            "--host" "0.0.0.0"
        ];
    };

    networking.firewall.allowedTCPPorts = [ 3035 ];
}
