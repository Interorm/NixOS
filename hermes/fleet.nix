{
    pkgs, config,
    ...
}: let

    enable_docling = true;

in {
    # Host-wide facts about the Hermes fleet: which speech backend, which
    # document pipeline, which gateway topology.  Properties of the HOST,
    # not of any one person -- per-account identity lives in ./users/, MCP
    # snippets in ./mcp/, profile presets in ./profiles/.
    services.lean-math = {
        enable = true;
        users = [ "karl" "joni" ];
    };

    services.docling = {
        enable = enable_docling;
        gpu = "0";
        memoryFraction = "0.24";
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Gemma4-E4B";

        dashboardHost = "0.0.0.0";
        dependencyGroups = [ "messaging" "anthropic" ];

        secretsBackend = "agenix";
        doclingPdfHook.enable = enable_docling;

        # No fleet-wide MCP servers, deliberately.  Every MCP a profile
        # loads puts its tool schemas into the prefill of every request
        # that profile makes, so a server nobody in a given role needs is
        # pure token cost.  Servers are named per profile (hermes/profiles/
        # via the ./mcp registry) or per agent (hermes/users/<name>.nix),
        # never globally.
        mcpServers = { };

        settings = {
            stt = {
                enabled = true;
                provider = "openai";
                language = "";
                openai = {
                    base_url = "http://192.168.42.2:8110/v1";
                    model = "deepdml/faster-whisper-large-v3-turbo-ct2";
                    language = "";
                };
            };
            tts = {
                provider = "openai";
                openai = {
                    api_key = "empty-key";
                    base_url = "http://192.168.42.2:8110/v1";
                    model = "speaches-ai/Kokoro-82M-v1.0-ONNX";
                    voice = "af_heart";
                };
            };

            # Make each agent's ONE gateway serve every profile in that
            # agent's home, rather than only the top-level profile.
            #
            # This is REQUIRED for per-profile cron to work at all, and the
            # failure mode without it is silent.  Cron stores are
            # per-profile by design (cron/jobs.py anchors JOBS_FILE at the
            # ACTIVE profile's HERMES_HOME, explicitly rejecting a shared
            # root so a job runs with its own profile's .env/config/skills).
            # A non-multiplexing gateway only ticks the store belonging to
            # the profile it was launched as -- so a job created under
            # `hermes -p finance` lands in profiles/finance/cron/jobs.json,
            # which no ticker owns.  It then sits there looking perfectly
            # scheduled and never fires (upstream #4707 / #25290 / #32091).
            #
            # With this on, the built-in ticker walks EVERY served profile's
            # cron store each cycle, with heartbeats and recovery scoped per
            # profile, and startup MCP discovery likewise runs once per
            # profile.  Note an external cron.provider cannot do this and
            # fails closed to the built-in ticker.
            #
            # Fleet-wide rather than per-agent: "one gateway per Unix user
            # serves that user's profiles" is a property of this host's
            # topology, like modelBaseUrl -- and an agent that silently had
            # it off would have dead cron jobs with no visible cause.
            gateway.multiplex_profiles = true;
        };
    };
}
