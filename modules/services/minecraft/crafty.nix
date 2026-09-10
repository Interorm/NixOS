{
    pkgs,
    ...
}: let
    dataDir = "/var/lib/Minecraft/docker";

    owner = "homeserver";
in {

    systemd.tmpfiles.rules = [
        "d ${dataDir}         2775 ${owner} root - -"
        "d ${dataDir}/backups 2775 ${owner} root - -"
        "d ${dataDir}/logs    2775 ${owner} root - -"
        "d ${dataDir}/servers 2775 ${owner} root - -"
        "d ${dataDir}/config  2775 ${owner} root - -"
        "d ${dataDir}/import  2775 ${owner} root - -"
    ];

    systemd.services.crafty-permissions = {
        description = "Repair Crafty bind mount ownership";

        requiredBy = [ "docker-crafty.service" ];
        before = [ "docker-crafty.service" ];

        serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
        };

        script = ''
            ${pkgs.coreutils}/bin/chown -R ${owner}:root ${dataDir}
            ${pkgs.findutils}/bin/find ${dataDir} -type d -exec ${pkgs.coreutils}/bin/chmod 2775 {} +
            ${pkgs.findutils}/bin/find ${dataDir} -type f -exec ${pkgs.coreutils}/bin/chmod g+rw {} +
        '';
    };

    virtualisation.oci-containers.containers.crafty = {
        image = "registry.gitlab.com/crafty-controller/crafty-4:latest";
        environment.TZ = "Etc/UTC";
        ports = [ "25565-25569:25565-25569" "2000:8443" ];
        volumes = [
            "${dataDir}/backups:/crafty/backups"
            "${dataDir}/logs:/crafty/logs"
            "${dataDir}/servers:/crafty/servers"
            "${dataDir}/config:/crafty/app/config"
            "${dataDir}/import:/crafty/import"
        ];
    };

    networking.firewall.allowedTCPPorts = [ 2000 25565 25566 25567 25568 25569 ];
}
