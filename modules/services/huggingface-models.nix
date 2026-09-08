{
    config, lib, pkgs,
    ...
}: let
    cfg = config.services.huggingface-models;

    # The `hf` CLI ships inside the huggingface-hub Python package; wrapping it
    # in a withPackages env gives us a stable store path with `bin/hf` in it.
    #
    # If you want saturated downloads, add `ps.hf-transfer` here as well and the
    # HF_HUB_ENABLE_HF_TRANSFER=1 below starts doing something.  It is left out
    # by default so that a missing/renamed attribute cannot break evaluation of
    # the whole system.
    hfCli = pkgs.python3.withPackages (ps: [ ps.hf-transfer ps.huggingface-hub ]);

    # The stable, constant path a server module points at.  Note this depends
    # only on `directory` and `models`, never on `paths` itself -- no cycle.
    modelPath = name: model: "${cfg.directory}/${model.target}";

    downloadUnit = name: model: lib.nameValuePair "hf-model-${name}" (let
        target  = modelPath name model;
        staging = "${cfg.directory}/.staging/${name}";
        # With --local-dir, hf reproduces the repo's internal layout, so a repo
        # path like "gguf/model-q4.gguf" lands at "$staging/gguf/model-q4.gguf".
        src     = if model.file == null then staging else "${staging}/${model.file}";
    in {
        description = "Fetch ${model.repo}"
            + lib.optionalString (model.file != null) " :: ${model.file}";

        # network-online (not just network) -- DNS has to actually resolve.
        wantedBy = [ "multi-user.target" ];
        wants    = [ "network-online.target" ];
        after    = [ "network-online.target" ];

        # `!` negates the condition: skip the unit entirely once the model is
        # in place.  This is what makes the unit idempotent and cheap on every
        # subsequent boot -- no hashing, no HTTP round-trip, systemd just marks
        # it as skipped and downstream `After=` ordering is still satisfied.
        unitConfig.ConditionPathExists = "!${target}";

        path = [ hfCli pkgs.coreutils ];

        environment = {
            # Keep the HF cache next to the models rather than in /root/.cache,
            # so one `rm -rf` reclaims everything.
            HF_HOME = "${cfg.directory}/.cache";
            HF_HUB_ENABLE_HF_TRANSFER = "1";
            HF_HUB_DISABLE_TELEMETRY = "1";
        };

        serviceConfig = {
            Type = "oneshot";

            # Without this the unit would flap back to "inactive" and any
            # `Requires=` on it would re-trigger the download.
            RemainAfterExit = true;

            # CRITICAL.  systemd's default start timeout is 90 seconds; a 27B
            # model is tens of gigabytes.  Without this the unit is killed
            # mid-transfer, forever.
            TimeoutStartSec = "infinity";

            # Downloads are the one thing worth retrying automatically.
            Restart = "on-failure";
            RestartSec = "60";
        } // lib.optionalAttrs (cfg.tokenFile != null) {
            EnvironmentFile = cfg.tokenFile;
        };

        script = ''
            set -euo pipefail

            # Always start from a clean staging dir: a half-finished previous
            # attempt must never be promoted to the final path.
            rm -rf ${lib.escapeShellArg staging}
            mkdir -p ${lib.escapeShellArg staging}

            hf download \
                ${lib.escapeShellArg model.repo} \
                ${lib.optionalString (model.file != null) (lib.escapeShellArg model.file)} \
                --revision ${lib.escapeShellArg model.revision} \
                --local-dir ${lib.escapeShellArg staging}

            # rename(2) within one filesystem is atomic, so `target` either does
            # not exist or is a complete file.  That is exactly the invariant
            # ConditionPathExists on the *server* units relies on.
            mv -fT ${lib.escapeShellArg src} ${lib.escapeShellArg target}

            rm -rf ${lib.escapeShellArg staging}
        '';
    });
in {
    options.services.huggingface-models = {
        directory = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/llama/models";
            description = ''
                Mutable directory holding the downloaded weights.  Deliberately
                NOT in the Nix store: model blobs are multi-gigabyte, are not
                content-addressable in a useful way (HF repos are mutable
                unless you pin a commit sha), and the store is read-only, which
                rules out resumable downloads.
            '';
        };

        tokenFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            example = "/etc/hf-token.env";
            description = ''
                Path to a systemd EnvironmentFile containing `HF_TOKEN=hf_...`,
                for gated repos (Llama, Gemma, ...).  Must NOT live in the repo
                -- it is a secret, and anything in the flake ends up
                world-readable in /nix/store.  Create it out of band with
                mode 0400 root:root, or hand it over via sops-nix/agenix later.
            '';
        };

        models = lib.mkOption {
            default = {};
            description = "Models to fetch from the Hugging Face Hub.";
            example = lib.literalExpression ''
                {
                  qwen-coder = {
                    repo   = "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF";
                    file   = "qwen2.5-coder-7b-instruct-q4_k_m.gguf";
                    target = "Qwen2.5-Coder-7B-Q4.gguf";
                  };
                }
            '';
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                options = {
                    repo = lib.mkOption {
                        type = lib.types.str;
                        description = "Hub repo id, e.g. \"Qwen/Qwen3-8B-GGUF\".";
                    };

                    file = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                            Single file to fetch, as named *inside the repo*.
                            null fetches the whole repo into a directory.
                        '';
                    };

                    revision = lib.mkOption {
                        type = lib.types.str;
                        default = "main";
                        description = ''
                            Branch, tag or commit sha.  Pin a commit sha if you
                            care about reproducibility -- "main" moves.
                        '';
                    };

                    target = lib.mkOption {
                        type = lib.types.str;
                        default = name;
                        description = ''
                            Filename under `directory`.  This is the constant
                            path your server units point at, deliberately
                            decoupled from upstream's naming so that switching
                            quantisations does not touch the service module.
                        '';
                    };
                };
            }));
        };

        paths = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            readOnly = true;
            default = {};
            description = ''
                Read-only map from model name to its absolute on-disk path.
                Consume it from service modules:
                  config.services.huggingface-models.paths.qwen-coder
            '';
        };
    };

    config = {
        services.huggingface-models.paths = lib.mapAttrs modelPath cfg.models;

        systemd.tmpfiles.rules = [
            "d ${cfg.directory}          0755 root root - -"
            "d ${cfg.directory}/.cache   0700 root root - -"
            "d ${cfg.directory}/.staging 0700 root root - -"
        ];

        systemd.services = lib.mapAttrs' downloadUnit cfg.models;
    };
}
