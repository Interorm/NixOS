{
    pkgs, config,
    ...
}: let

    enable_docling = true;

in {

    services.docling = {
        enable = enable_docling;
        gpu = "0";
        memoryFraction = "0.24";
    };

    services.hermes-agents = {
        enable = true;

        defaultModel = "Qwen3.8-27B";

        dashboardHost = "0.0.0.0";
        dependencyGroups = [ "messaging" "anthropic" ];

        secretsBackend = "agenix";
        doclingPdfHook.enable = enable_docling;

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

            # Vision auxiliary model for the whole fleet.  Every agent's main
            # model is text-only (Qwen3.8-27B), so an image attached to a
            # session has no describer and the feature is dead: hermes' aux
            # resolver defaults to provider "auto" + empty model, and the
            # fleet's only vision-capable model is Gemma4-E4B.  Pinning it
            # here -- the same attrset that carries the fleet stt/tts pins --
            # makes "every image needs a describer" a fleet property: one
            # switch, single source of truth, instead of a per-agent copy.
            #
            # base_url is the gateway (modelBaseUrl), not the vision
            # backend's :8070 directly: the gateway is this host's
            # model-addressing topology -- it routes by model id, so
            # "Gemma4-E4B" reaches the chat endpoint while Qwen keeps the
            # others.  Deriving it from modelBaseUrl (the exact value the
            # module's own `model` block already writes at hermes.nix:414)
            # keeps the gateway port declared once.
            #
            # api_key: the gateway ignores the bearer value
            # (hermes.nix:657); the literal ${OPENAI_API_KEY} placeholder is
            # expanded by hermes from the agent's .env at runtime, exactly
            # like the main model block.  Verified against the running
            # hermes-agent source: _resolve_task_provider_model
            # (agent/auxiliary_client.py) resolves provider "custom" +
            # base_url + api_key to a working custom endpoint, and
            # _expand_env_vars (hermes_cli/config.py) expands ${VAR} in every
            # string value at load time.
            auxiliary.vision = {
                provider = "custom";
                model = "Gemma4-E4B";
                base_url = config.services.hermes-agents.modelBaseUrl;
                api_key = "\${OPENAI_API_KEY}";
            };
        };
    };
}
