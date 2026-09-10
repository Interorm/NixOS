{
    pkgs, ...
}: {
    systemd.services.init-openwebui-net = {
        description = "Create the OpenWebUI_net docker network";

        after = [ "docker.service" "docker.socket" ];
        requires = [ "docker.service" ];

        requiredBy = [];
        before = [];

        serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
        };

        script = ''
            ${pkgs.docker}/bin/docker network inspect OpenWebUI_net >/dev/null 2>&1 \
                || ${pkgs.docker}/bin/docker network create OpenWebUI_net
        '';
    };
}