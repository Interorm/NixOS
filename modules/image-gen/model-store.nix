{
    config, lib, pkgs,
    ...
}: let
    cfg = config.services.imageGen.modelStore;

    # One fetch derivation per model.  `nix build` of any of these (or the
    # aggregate below) downloads exactly that model and nothing else -- this is
    # what keeps Karl in control of the ~130 GB instead of a rebuild pulling it
    # all at once.
    fetchDerivation = name: model:
        pkgs.runCommand "image-model-${name}" {
            inherit (model) destFile;
        } ''
            mkdir -p $out/models/${model.type}
            cp ${model.fetch} $out/models/${model.type}/${model.destFile}
            chmod 644 $out/models/${model.type}/${model.destFile}
        '';

    # Per-model fetch source: pinned fetchurl when a hash was given, otherwise
    # plain fetchurl (no SRI).  Hugging Face `resolve/main/...` URLs are stable
    # for immutable files, so an unpinned entry still lands the same bytes --
    # but pin `sha256` anyway when you can: it is what makes a re-fetch fail
    # loudly instead of silently swapping weights under a running service.
    fetchSource = name: model:
        if model.sha256 != null then
            pkgs.fetchurl {
                url = model.url;
                sha256 = model.sha256;
            }
        else
            pkgs.fetchurl {
                url = model.url;
            };

    # The single store path every consumer points at.  Depends only on
    # `storeDir`, never on the fetch derivations -- no cycle, and flipping
    # `enablePull` does not move it.
    modelPath = name: model: "${cfg.storeDir}/models/${model.type}/${model.destFile}";

    # A model is an "addition" when it names a baseModel.  Group those by base
    # so a workflow (or a human) can see which LoRAs load with which checkpoint
    # without re-deriving it from the declarations.
    additionsByBase =
        lib.groupBy (m: m.baseModel) (lib.filter (m: m.baseModel != null) cfg.models);

in {
    options.services.imageGen.modelStore = {
        enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
                Enable the model store: option validation, the derived
                `paths`/`configs` views, the manifest and the tmpfiles rules.
                With `enablePull = false` (the default) this pulls nothing --
                declarations only.
            '';
        };

        enablePull = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
                Wire the per-model fetch derivations into the system closure
                (`systemd.tmpfiles.rules` copies them into place at activation,
                idempotently -- existing files are never overwritten).  Keep
                this off while you pull explicitly with
                `nix build .#image-gen-models.<name>` or
                `nix build .#image-gen-models.all`; flip it on to have the next
                rebuild materialise everything declared.
            '';
        };

        storeDir = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/comfyui";
            description = ''
                Mutable root holding the downloaded weights, mirroring the
                llama.cpp huggingface module's `directory`.  Deliberately NOT
                in the Nix store: model blobs are multi-gigabyte and the store
                is read-only, which rules out resumable downloads.  Defaults to
                the utensils ComfyUI `dataDir` so models land where the service
                looks; do not change it later -- state is not migrated.
            '';
        };

        models = lib.mkOption {
            default = {};
            description = "Models to pull and store.";
            example = lib.literalExpression ''
                {
                  qwen-image-2512 = {
                    url      = "https://huggingface.co/unsloth/Qwen-Image-2512-GGUF/resolve/main/Qwen-Image-2512-Q6_K.gguf";
                    sha256   = "…";
                    destFile = "qwen-image-2512-Q6_K.gguf";
                    type     = "diffusion_models";
                  };
                  snofs-lora = {
                    url       = "https://huggingface.co/rkppvc/qwen_snofs_v13/resolve/main/snofs-v13.safetensors";
                    destFile  = "snofs-v13.safetensors";
                    type      = "loras";
                    baseModel = "qwen-image-2512";
                  };
                }
            '';
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
                options = {
                    url = lib.mkOption {
                        type = lib.types.str;
                        description = ''
                            Direct download URL -- typically a Hugging Face
                            `resolve/<rev>/<file>` link.
                        '';
                    };

                    sha256 = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                            Optional SRI hash.  When present the fetch is
                            content-pinned; when absent the fetch trusts the
                            URL as-is.
                        '';
                    };

                    destFile = lib.mkOption {
                        type = lib.types.str;
                        default = name;
                        description = ''
                            Filename under `models/<type>/`.  Decoupled from
                            upstream naming so switching quantisations does not
                            touch anything that references the path.
                        '';
                    };

                    type = lib.mkOption {
                        type = lib.types.str;
                        default = "other";
                        description = ''
                            ComfyUI model folder: checkpoints, diffusion_models,
                            clip, loras, vae, embeddings, controlnet, upscaler,
                            or any other string.
                        '';
                    };

                    baseModel = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = ''
                            Name of another entry this model associates with
                            (a LoRA pointing at its base checkpoint).  Feeds the
                            `configs` view and the JSON manifest.
                        '';
                    };

                    description = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Free-text note shown in the manifest.";
                    };
                };
            }));
        };

        paths = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            readOnly = true;
            description = ''
                Read-only map from model name to its absolute on-disk path.
                Consume it from service modules:
                  config.services.imageGen.modelStore.paths.qwen-image-2512
            '';
        };

        configs = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
            readOnly = true;
            description = ''
                Additions grouped by base model: `configs.<base>.<name>` carries
                `{ type, destFile, description }`.  Entries without a
                `baseModel` do not appear here.
            '';
        };

        manifest = lib.mkOption {
            type = lib.types.path;
            readOnly = true;
            description = ''
                Pure-Nix rendering of the association data as JSON -- the
                artifact workflows (or a human) read to know which LoRAs load
                with which base.  Written to `<storeDir>/model-manifest.json`
                at activation.
            '';
        };
    };

    config = lib.mkIf cfg.enable {
        services.imageGen.modelStore = {
            paths = lib.mapAttrs modelPath cfg.models;

            configs = additionsByBase;

            manifest =
                let
                    json = builtins.toJSON {
                        generatedFrom = "services.imageGen.modelStore";
                        storeDir = cfg.storeDir;
                        # Self-contained on purpose: a workflow (or a human)
                        # reads ONLY this file to know where the base lives and
                        # which additions load with it -- no `paths` join needed.
                        bases = lib.mapAttrs (base: members: {
                            base =
                                let
                                    baseEntry = cfg.models.${base} or null;
                                in
                                if baseEntry == null then
                                    null
                                else {
                                    inherit (baseEntry) type destFile;
                                    path = modelPath base baseEntry;
                                };
                            additions = lib.mapAttrs (name: m: {
                                inherit (m) type destFile description;
                                path = modelPath name m;
                            }) members;
                        }) additionsByBase;
                    };
                in
                pkgs.writeText "model-manifest.json" json;
        };

        systemd.tmpfiles.rules = [
            "d ${cfg.storeDir}          0755 root root - -"
            "d ${cfg.storeDir}/models   0755 root root - -"
        ] ++ lib.optionals cfg.enablePull (
            # Copy each fetched model into place, skipping files that already
            # exist (idempotent across rebuilds; hand-placed files win).
            lib.mapAttrsToList (name: model:
                "z! ${cfg.storeDir}/models/${model.type}/${model.destFile} 0644 root root - - ${fetchDerivation name model}/models/${model.type}/${model.destFile}")
            cfg.models
        ) ++ [
            # Manifest: always rewritten (it is derived, not user state).
            "w! ${cfg.storeDir}/model-manifest.json 0644 root root - - ${config.services.imageGen.modelStore.manifest}"
        ];

        # Explicit pull surface: `nix build .#imageGenModels.all` (everything)
        # or `.#imageGenModels.<name>` (one model).  Building these is what
        # downloads.  Exposed REGARDLESS of enablePull: with enablePull=false
        # (the default) the system closure contains none of these derivations,
        # so this attr is the only way to pull explicitly without flipping the
        # flag; with enablePull=true tmpfiles also materialises them at
        # activation (idempotently).
        imageGenModels =
            lib.mapAttrs (name: model: fetchDerivation name model) cfg.models
            // {
                all = pkgs.runCommand "image-gen-models-all" {} ''
                    mkdir -p $out
                    ${lib.concatMapStringsSep "\n" (name: model:
                        "cp -r ${fetchDerivation name model}/models/* $out/") cfg.models}
                '';
            };
    };
}
