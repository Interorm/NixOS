{
    pkgs,
    lib,
    config,
    ...
}: let
    version = "2.10.19";

    cfg = config.services.firecrawl;

    postgres = {
        user = "postgres";
        password = "postgres";
        db = "postgres";
    };

in {

    options.services.firecrawl = {
        enable = lib.mkEnableOption;

        host = lib.mkOption { type = lib.types.str; default = "0.0.0.0"; };
        port = lib.mkOption { type = lib.types.port; default = 3030; };
        network = lib.mkOption { type = lib.types.str; default = "firecrawl_net"; };

        memory = lib.mkOption { type = lib.types.str; default = "4g"; };
        memory-playwright = lib.mkOption { type = lib.types.str; default = "2g"; };
    };

    config = lib.mkIf cfg.enable {
        # oci-containers has no notion of compose's implicit per-project network,
        # so the bridge is created explicitly.  Container-to-container DNS
        # (redis, rabbitmq, nuq-postgres, playwright-service) only works on a
        # user-defined network -- the default bridge would resolve none of them.
        systemd.services.init-firecrawl-net = {
            description = "Create the ${cfg.network} docker network";

            after = [ "docker.service" "docker.socket" ];
            requires = [ "docker.service" ];

            requiredBy = [
                "docker-firecrawl-api.service"
                "docker-firecrawl-playwright.service"
                "docker-firecrawl-redis.service"
                "docker-firecrawl-rabbitmq.service"
                "docker-firecrawl-postgres.service"
            ];
            before = [
                "docker-firecrawl-api.service"
                "docker-firecrawl-playwright.service"
                "docker-firecrawl-redis.service"
                "docker-firecrawl-rabbitmq.service"
                "docker-firecrawl-postgres.service"
            ];

            serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
            };

            script = ''
                ${pkgs.docker}/bin/docker network inspect ${cfg.network} >/dev/null 2>&1 \
                    || ${pkgs.docker}/bin/docker network create ${cfg.network}
            '';
        };

        virtualisation.oci-containers.containers = {

            firecrawl-api = {
                image = "ghcr.io/firecrawl/firecrawl:${version}";
                ports = [ "${cfg.host}:${toString cfg.port}:${toString cfg.port}" ];

                environment = {
                    HOST = cfg.host;
                    PORT = toString cfg.port;
                    ENV = "local";

                    # Hostnames, not localhost: inside a container localhost is
                    # the container itself, never a sibling service.
                    REDIS_URL = "redis://firecrawl-redis:6379";
                    REDIS_RATE_LIMIT_URL = "redis://firecrawl-redis:6379";
                    NUQ_RABBITMQ_URL = "amqp://firecrawl-rabbitmq:5672";
                    PLAYWRIGHT_MICROSERVICE_URL = "http://firecrawl-playwright:3000/scrape";

                    POSTGRES_HOST = "firecrawl-postgres";
                    POSTGRES_PORT = "5432";
                    POSTGRES_USER = postgres.user;
                    POSTGRES_PASSWORD = postgres.password;
                    POSTGRES_DB = postgres.db;

                    # The queue runs on Postgres.  Leaving NUQ_BACKEND unset keeps
                    # the experimental FoundationDB path -- and its two extra
                    # containers and shared cluster-file volume -- out entirely.
                    USE_DB_AUTHENTICATION = "false";

                    EXTRACT_WORKER_PORT = "3004";
                    WORKER_PORT = "3005";
                    HARNESS_STARTUP_TIMEOUT_MS = "60000";

                    NUM_WORKERS_PER_QUEUE = "4";
                    CRAWL_CONCURRENT_REQUESTS = "4";
                    MAX_CONCURRENT_JOBS = "3";
                    BROWSER_POOL_SIZE = "2";

                    LOGGING_LEVEL = "info";
                };

                cmd = [ "node" "dist/src/harness.js" "--start-docker" ];

                dependsOn = [
                    "firecrawl-redis"
                    "firecrawl-rabbitmq"
                    "firecrawl-postgres"
                    "firecrawl-playwright"
                ];

                extraOptions = [
                    "--network=${cfg.network}"
                    "--memory=${cfg.memory}"
                    "--cpus=4"
                    # The API forks a worker per queue and each opens its own
                    # sockets; the stock 1024 limit is exhausted under a crawl.
                    "--ulimit=nofile=65535:65535"
                ];
            };

            firecrawl-playwright = {
                image = "ghcr.io/firecrawl/playwright-service:latest";

                environment = {
                    PORT = "3000";
                    MAX_CONCURRENT_PAGES = "4";

                    # Both are parsed as booleans by a Zod schema that rejects the
                    # empty string, and an unset variable arrives as exactly that.
                    # Leaving them out crashes the container at startup.
                    BLOCK_MEDIA = "false";
                    ALLOW_LOCAL_WEBHOOKS = "false";
                };

                extraOptions = [
                    "--network=${cfg.network}"
                    "--memory=${cfg.memory-playwright}"
                    "--cpus=2"
                    # Chromium's profile cache, kept off the container's writable
                    # layer so a long crawl cannot fill the docker data root.
                    "--tmpfs=/tmp/.cache:noexec,nosuid,size=512m"
                ];
            };

            firecrawl-redis = {
                image = "docker.io/redis:alpine";
                cmd = [ "redis-server" "--bind" "0.0.0.0" ];
                extraOptions = [
                    "--network=${cfg.network}"
                    "--memory=256m"
                ];
            };

            firecrawl-rabbitmq = {
                image = "docker.io/rabbitmq:3-management";
                cmd = [ "rabbitmq-server" ];
                extraOptions = [
                    "--network=${cfg.network}"
                    # 512m is a floor, not a preference: RabbitMQ's flow-control
                    # watermark is 40% of this, and below it the broker raises a
                    # memory alarm at boot and blocks every publisher.
                    "--memory=512m"
                ];
            };

            firecrawl-postgres = {
                image = "ghcr.io/firecrawl/nuq-postgres:latest";

                environment = {
                    POSTGRES_USER = postgres.user;
                    POSTGRES_PASSWORD = postgres.password;
                    POSTGRES_DB = postgres.db;
                };

                extraOptions = [
                    "--network=${cfg.network}"
                    "--memory=512m"
                ];
            };
        };
    };
}
