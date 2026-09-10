{
    ...
}: {
    virtualisation.oci-containers.containers.crafty = {
        image = "registry.gitlab.com/crafty-controller/crafty-4:latest";
        environment.TZ = "Etc/UTC";
        ports = [ "25565-25569:25565-25569" "2000:8443" ];
        volumes = [
            "/var/lib/Minecraft/docker/backups:/crafty/backups"
            "/var/lib/Minecraft/docker/logs:/crafty/logs"
            "/var/lib/Minecraft/docker/servers:/crafty/servers"
            "/var/lib/Minecraft/docker/config:/crafty/app/config"
            "/var/lib/Minecraft/docker/import:/crafty/import"
        ];
    };
    networking.firewall.allowedTCPPorts = [ 2000 25565 25566 25567 25568 25569 ];
}