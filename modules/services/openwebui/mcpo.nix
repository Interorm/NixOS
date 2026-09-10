{
    pkgs, 
    ...
}: let 

    mcpoConfig = (pkgs.formats.json { }).generate "mcpo-config.json" {
        mcpServers = {
            sequential-thinking = {
                command = "npx";
                args = [ "-y" "@modelcontextprotocol/server-sequential-thinking" ];
            };
        };
    };

in {

    systemd.services.init-openwebui-net = {
        requiredBy = ["docker-mcpo.service"];
        before = ["docker-mcpo.service"];
    };

    virtualisation.oci-containers.containers = {
        mcpo = {
            image = "ghcr.io/open-webui/mcpo:main";
            ports = [ "3060:8000" ];
            cmd = [ "--config" "/app/config.json" "--api-key" "empty-key" ];
            volumes = [ "${mcpoConfig}:/app/config.json:ro" ];
            extraOptions = [ "--network=OpenWebUI_net" ];
        };
    };

    networking.firewall.allowedTCPPorts = [ 3060 ];
}