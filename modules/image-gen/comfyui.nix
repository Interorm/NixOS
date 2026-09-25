{
    inputs, lib, config,
    ...
}: {
    # ComfyUI -- local image generation (Karls-PC).
    #
    # WHY THIS FLAKE: stock nixpkgs `comfyui` cannot reach prebuilt CUDA torch
    # (NixOS/nixpkgs#553299; fixes in #564687 + #564686, open as of 2026-09-19),
    # so it would source-build torch for hours on this box. utensils/comfyui-nix
    # ships a native systemd unit backed by prebuilt sm_120-capable cu13x PyTorch
    # wheels (torch 2.10.0+cu130 at the pinned commit -- NOT 2.13.0, which the
    # decision report misstated) and auto-disables nixpkgs' own services.comfyui
    # (disabledModules), so it stays safe across a `nix flake update`. TEMPORARY
    # BY DESIGN: one pinned input, deleted when the native module migrates.
    #
    # ONE UNIT, TWO SURFACES: ComfyUI serves BOTH the web UI AND its JSON API from
    # the same systemd unit (`systemd.services.comfyui`) on a single port
    # (default 8188). The UI is what Karl opens in a browser; the JSON API is what
    # homeserver-hosted services call to embed image generation. There is no
    # second service or port -- "LAN-reachable service" and "the comfy UI" are the
    # same process.
    #
    # SAFETY AUDIT (t_45eeecc9): SAFE_WITH_CONDITIONS. All three conditions are
    # implemented here:
    #   C1 -- pin nixpkgs via the follow. The flake's own nixpkgs input is UNPINNED
    #         (floats nixos-unstable) and the repo ships no flake.lock, so the
    #         integration card must declare the input as
    #             inputs.comfyui-nix.inputs.nixpkgs.follows = "nixpkgs";
    #         so its packageSet resolves against Karl's locked, trusted nixpkgs
    #         instead of floating. (This module consumes inputs.comfyui-nix but
    #         does not edit flake.nix -- that is the integration card's job.)
    #   C2 -- loopback by default; LAN exposure is an explicit opt-in. See below.
    #   C3 -- Manager network posture documented (upstream exposes no option to
    #         tighten it). See below.
    #
    # EMBEDDING / API (verified against Comfy-Org/ComfyUI v0.34.0 server.py at the
    # pinned version): base URL http://<karls-pc-lan-ip>:8188 once LAN-exposed.
    #   POST /prompt        submit a workflow graph -> {"prompt_id": "..."}
    #   GET  /queue         {"queue_running": [...], "queue_pending": [...]}
    #   GET  /history       completed outputs (per prompt_id)
    #   GET  /system_stats  device + ram (primary_device.name == RTX 5090)
    #   GET  /ws            websocket: progress / executing / status events
    #   GET  /object_info   node schemas (build graphs programmatically)
    # Minimal txt2img submit (workflow built from /object_info):
    #   curl -s -X POST http://<lan-ip>:8188/prompt \
    #     -H 'Content-Type: application/json' \
    #     -d '{"prompt": {"3": {"class_type":"KSampler","inputs":{...}},
    #              "4": {"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"z_image_turbo.safetensors"}},
    #              "6": {"class_type":"EmptyLatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
    #              "8": {"class_type":"VAEDecode","inputs":{"samples":"[3,0]"}},
    #              "9": {"class_type":"SaveImage","inputs":{"filename_prefix":"out","images":"[8,0]"}}},
    #      "client_id": "imagegen"}'
    # Then poll GET /queue until empty and read GET /history/<prompt_id>. No auth
    # exists -- reachability IS the security boundary (see C2).
    #
    # FIRST BUILD: may download ~2 GB of prebuilt torch wheels from pytorch.org if
    # comfyui.cachix.org has no closure for Karl's exact locked nixpkgs rev.
    # Harmless -- the env assembles locally, there is NO torch compile. (Report §4.)
    imports = [ inputs.comfyui-nix.nixosModules.default ];

    services.comfyui = {
        enable = true;

        # Prebuilt PyTorch cu130 wheels (torch 2.10.0+cu130, torchvision
        # 0.25.0+cu130) include sm_120 kernels -- required for the RTX 5090
        # (Blackwell consumer); cu12x wheels fail on sm_120 with
        # cudaErrorNoKernelImageForDevice. Requires NVIDIA driver >= 580;
        # modules/hardware/nvidia.nix selects nvidiaPackages.stable (595.x).
        gpuSupport = "cuda";

        # ComfyUI-Manager 4.2.2: runtime custom-node/model management into dataDir.
        #
        # C3 (safety audit): the upstream module exposes NO option to adjust the
        # Manager's network posture. On first run it copies a default config with
        # security_level = normal and network_mode = personal_cloud
        # (utensils nix/packages.nix:179-180) -- a deliberately relaxed "trusted
        # environment" mode that phones home to comfyui.com for update checks.
        # Accepted on a trusted home LAN. If this service is ever reachable beyond
        # a trusted segment, tighten network_mode (private/offline) and
        # security_level (strong) in <dataDir>/user/__manager/config.ini.
        enableManager = true;

        port = 8188;

        # C2 (safety audit): loopback by default. ComfyUI has no built-in auth, and
        # the bundled model-downloader node (always active, not gated on
        # --enable-manager) registers POST /model-downloader/download with an
        # unvalidated caller-supplied URL -- an SSRF vector
        # (src/custom_nodes/model_downloader/model_downloader_patch.py:433). LAN
        # exposure must be an explicit, documented opt-in. To expose it on the LAN
        # (Karl's requirement; trust model = same as xrdp), flip exactly these two
        # lines in hosts/PC/default.nix:
        #       listenAddress = "0.0.0.0";
        #       openFirewall  = true;
        # Known exposure when flipped: the unauthenticated model-downloader SSRF
        # endpoint above (audit t_45eeecc9). Off-site access: bind the Tailscale IP
        # instead (listenAddress = "100.x.y.z") -- no LAN exposure at all.
        listenAddress = "127.0.0.1";
        openFirewall = false;

        # Persistent StateDirectory (tmpfiles 0750, user comfyui). Models under
        # models/<type>/, outputs under output/, comfyui.db, and the PEP 405 venv
        # at .venv/ all survive rebuilds. Do NOT change dataDir later -- state is
        # not migrated. Keep it a dedicated path: the launcher rm -rf's any
        # non-symlink directory under custom_nodes/ whose name collides with a
        # bundled node on every start (hand-managed nodes with bundled names are
        # replaced on restart).
        dataDir = "/var/lib/comfyui";
    };

    # SUBSTITUTERS -- gotcha: a flake's `nixConfig` only applies when THAT flake is
    # the top-level build, not when imported as an input, so the host must trust
    # these caches itself or first builds fall back to wheel downloads (~2 GB;
    # still no torch compile). This is the UNION of the flake's own nixConfig
    # (comfyui, nix-community, cuda-maintainers -- verified at the pinned commit)
    # plus cache.nixos.org and cache.nixos-cuda.org. Declared as plain lists
    # (append semantics) so it composes with modules/development/cuda.nix's
    # existing cache.nixos-cuda.org entry rather than clobbering it.
    # NOTE on keys: the cache.nixos.org public key below is the CANONICAL value
    # (verified against the running system's `nix show-config`), NOT the one
    # printed in the decision report §3.2 -- that report's key string is
    # corrupted, the same class of error as its "torch 2.13.0" misstatement.
    nix.settings.substituters = [
        "https://cache.nixos.org"
        "https://cache.nixos-cuda.org"
        "https://nix-community.cachix.org"
        "https://comfyui.cachix.org"
        "https://cuda-maintainers.cachix.org"
    ];
    nix.settings.trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "comfyui.cachix.org-1:33mf9VzoIjzVbp0zwj+fT51HG0y31ZTK3nzYZAX0rec="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
}
