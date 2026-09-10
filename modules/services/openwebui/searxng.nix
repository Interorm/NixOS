{
    pkgs,
    ...
}: let

    settings = (pkgs.formats.yaml { }).generate "settings.yml" {
        use_default_settings = true;

        server = {
            secret_key = "empty-key";
            image_proxy = true;
        };

        engines = [
            { name = "bing"; disabled = true; }
            { name = "duckduckgo"; disabled = true; }
            { name = "yahoo"; disabled = true; }
            { name = "qwant"; disabled = true; }
            { name = "brave"; disabled = true; }
            { name = "startpage"; disabled = true; }
            { name = "google"; disabled = false; }
        ];

        search.formats = [ "html" "json" ];
    };

    # The compose file mounted ./core-config/ as a *directory*, so the image
    # sees only the files that directory contains.  Reproduced as a store
    # directory rather than a host path: no state, nothing to keep in sync.
    #
    # Mounted :ro because that host directory only ever held settings.yml -- no
    # uwsgi.ini, no limiter.toml -- which means this image writes nothing into
    # /etc/searxng.  If a future image version does, the container will
    # crash-loop on startup with a permission error; the fix is then to render
    # this into /var/lib/searxng/config via a oneshot and mount that read-write.
    configDir = pkgs.runCommand "searxng-config" { } ''
        mkdir -p $out
        cp ${settings} $out/settings.yml
    '';

in {

    systemd.services.init-openwebui-net = {
        requiredBy = [
            "docker-searxng.service"
            "docker-searxng-valkey.service"
        ];
        before = [
            "docker-searxng.service"
            "docker-searxng-valkey.service"
        ];
    };

    virtualisation.oci-containers.containers = {
        searxng = {
            image = "docker.io/searxng/searxng:latest";
            ports = [ "3030:3030" ];

            environment = {
                SEARXNG_PORT = "3030";
            };

            volumes = [
                "${configDir}:/etc/searxng:ro"
                "searxng-core-data:/var/cache/searxng"
            ];

            extraOptions = [
                "--network=OpenWebUI_net"
                "--network-alias=searxng-core"
                "--network-alias=core"
            ];
        };

        searxng-valkey = {
            image = "docker.io/valkey/valkey:9-alpine";
            cmd = [ "valkey-server" "--save" "30" "1" "--loglevel" "warning" ];
            volumes = [ "searxng-valkey-data:/data" ];
            extraOptions = [
                "--network=OpenWebUI_net"
                "--network-alias=valkey"
            ];
        };
    };

    networking.firewall.allowedTCPPorts = [ 3030 ];
}
