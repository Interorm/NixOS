{
    pkgs,
    ...
}: let

    # Prebuilt images only.  oci-containers pulls, it never builds, so the
    # upstream compose file's `build:` stanzas are not an option here.
    #
    # Pinned to an exact tag, not :latest -- upstream ships several releases a
    # week and a floating tag would silently change the API contract under the
    # agents on every container restart.
    #
    # NOTE: the published images lag the source tree.  Upstream's self-host
    # guide pins v2.11.162, but ghcr has nothing above 2.10.19, so the env
    # contract below is taken from docker-compose.yaml at tag v2.10.19 -- the
    # revision these images were actually built from -- and not from main.
    version = "2.10.19";

    # Only the API is published, and only on loopback: the MCP server that
    # consumes it runs on this same host.  Nothing else needs to reach it, and
    # the stack is deliberately unauthenticated (USE_DB_AUTHENTICATION=false),
    # so it must not be on a port other machines can dial.
    apiPort = 3030;

    network = "firecrawl_net";

    # Sized for ~7G total rather than upstream's 12G, because llama.cpp owns
    # most of this box's RAM.  The concurrency knobs are lowered to match: the
    # defaults (BROWSER_POOL_SIZE 5, 10 concurrent requests) assume the 4G
    # Playwright container upstream ships, and would OOM-kill this 2G one.
    apiMemory = "4g";
    playwrightMemory = "2g";

    postgres = {
        user = "postgres";
        password = "postgres";
        # Must stay `postgres`: the bundled pg_cron configuration in the
        # nuq-postgres image targets that database name at initdb time.
        db = "postgres";
    };

in {

    # oci-containers has no notion of compose's implicit per-project network,
    # so the bridge is created explicitly.  Container-to-container DNS
    # (redis, rabbitmq, nuq-postgres, playwright-service) only works on a
    # user-defined network -- the default bridge would resolve none of them.
    systemd.services.init-firecrawl-net = {
        description = "Create the ${network} docker network";

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
            ${pkgs.docker}/bin/docker network inspect ${network} >/dev/null 2>&1 \
                || ${pkgs.docker}/bin/docker network create ${network}
        '';
    };

    virtualisation.oci-containers.containers = {

        firecrawl-api = {
            image = "ghcr.io/firecrawl/firecrawl:${version}";
            ports = [ "127.0.0.1:${toString apiPort}:${toString apiPort}" ];

            environment = {
                HOST = "0.0.0.0";
                PORT = toString apiPort;
                ENV = "local";

                # Hostnames, not localhost: inside a container localhost is
                # the container itself, never a sibling service.
                REDIS_URL = "redis://firecrawl-redis:6379";
                REDIS_RATE_LIMIT_URL = "redis://firecrawl-redis:6379";
                NUQ_RABBITMQ_URL = "amqp://firecrawl-rabbitmq:5672";
                PLAYWRIGHT_MICROSERVICE_URL =
                    "http://firecrawl-playwright:3000/scrape";

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
                "--network=${network}"
                "--memory=${apiMemory}"
                "--cpus=4"
                # The API forks a worker per queue and each opens its own
                # sockets; the stock 1024 limit is exhausted under a crawl.
                "--ulimit=nofile=65535:65535"
                "--log-opt=max-size=10m"
                "--log-opt=max-file=3"
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
                "--network=${network}"
                "--memory=${playwrightMemory}"
                "--cpus=2"
                # Chromium's profile cache, kept off the container's writable
                # layer so a long crawl cannot fill the docker data root.
                "--tmpfs=/tmp/.cache:noexec,nosuid,size=512m"
                "--log-opt=max-size=10m"
                "--log-opt=max-file=3"
            ];
        };

        firecrawl-redis = {
            image = "docker.io/redis:alpine";
            cmd = [ "redis-server" "--bind" "0.0.0.0" ];
            extraOptions = [
                "--network=${network}"
                "--memory=256m"
                "--log-opt=max-size=5m"
                "--log-opt=max-file=2"
            ];
        };

        firecrawl-rabbitmq = {
            image = "docker.io/rabbitmq:3-management";
            cmd = [ "rabbitmq-server" ];
            extraOptions = [
                "--network=${network}"
                # 512m is a floor, not a preference: RabbitMQ's flow-control
                # watermark is 40% of this, and below it the broker raises a
                # memory alarm at boot and blocks every publisher.
                "--memory=512m"
                "--log-opt=max-size=5m"
                "--log-opt=max-file=2"
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
                "--network=${network}"
                "--memory=512m"
                "--log-opt=max-size=10m"
                "--log-opt=max-file=3"
            ];
        };
    };
}
