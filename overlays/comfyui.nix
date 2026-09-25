# ComfyUI, pinned ahead of nixpkgs so Qwen-Image-2.1 works.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ALL VERSIONS AND HASHES LIVE IN THE `pins` BLOCK DIRECTLY BELOW.        │
# │  Nothing else in this file needs editing to move to a newer ComfyUI.     │
# └──────────────────────────────────────────────────────────────────────────┘
#
# WHY EVERY ONE OF THESE HAS TO BE PINNED TOGETHER
#
# nixpkgs' `comfyui` python env matches nixpkgs' ComfyUI version *exactly*:
# upstream bumps its companion packages in lockstep with each release, so an
# env built for 0.34.1 cannot run 0.37.0.  Verified by building it:
#
#     ModuleNotFoundError: No module named 'comfy_aimdo.storage'
#
# comfy/storage.py imports that at module load, so it is a hard boot failure,
# not a warning.  (comfyui-frontend-package being stale is "only" a startup
# warning -- upstream logs it and continues -- but the frontend/backend API
# contract does drift, so it is pinned too.)
#
#   package                     nixpkgs has   0.37.0 needs
#   comfy-aimdo                 0.4.15        0.5.5     <- boot blocker
#   comfy-kitchen               0.2.31        0.2.35
#   comfyui-frontend-package    1.49.6        1.52.7
#   comfyui-workflow-templates  0.11.48       0.11.66   (+ 8 sub-packages)
#   comfyui-embedded-docs       0.5.10        0.5.12
#
# HASHES
#
# The hashes below are filled in and verified against ComfyUI v0.37.0.  When
# you change a version in `pins`, set that entry's hash to `lib.fakeHash`,
# build, and Nix prints the real one:
#
#     nix build .#comfyui-with-manager --keep-going 2>&1 | grep -A2 'hash mismatch'
#         specified: sha256-AAAA...
#            got:    sha256-<paste this back into the pin>
#
# `--keep-going` collects every mismatch in one run instead of stopping at
# the first, which matters here because a ComfyUI bump usually moves most of
# these at once.  Two of the pins (comfy-aimdo, comfy-kitchen) are
# fetchFromGitHub, so their failures name a generic `source.drv`; resolve
# which is which with:
#
#     nix eval --raw .#comfyui-with-manager.passthru.python.pkgs.comfy-aimdo.src.drvPath
#
# HOW TO MOVE TO A NEWER COMFYUI LATER
#
#   1. `nix flake update comfyui-src`  (or repoint `comfyui-src` in flake.nix
#      at the newer release tag) -- the ComfyUI source itself has no hash
#      here, it is a flake input pinned by flake.lock.
#   2. Read the new companion versions out of upstream's requirements.txt and
#      the workflow-templates metadata, update `pins` below, set the changed
#      hashes back to `lib.fakeHash`, rebuild, paste the real hashes in.
#   3. The build must pass `--quick-test-for-ci` (a real server boot). That
#      test is what caught the aimdo break above -- keep it enabled.
#
# WHEN TO DELETE THIS FILE
#
# nixpkgs bumps comfyui and all of these together (0.34.1 -> 0.35.0 landed
# 2026-09-10).  Once nixpkgs' comfyui is >= the version you need, drop this
# overlay, drop the `comfyui-src` input, and set the module back to
# `pkgs.comfyui` / `pkgs.comfyui.tests.withManager`.
#
# BUILD COST WARNING: comfy-aimdo and comfy-kitchen are compiled from source
# (cmake; comfy-kitchen builds CUDA kernels for your torch cudaCapabilities).
# Changing their versions means no cache hit and a long local build.
{ src }:
final: prev:
let
  lib  = final.lib;
  base = prev.comfyui;

  # ══════════════════════════════════════════════════════════════════════════
  #  PINS -- edit here, nowhere else.
  #  Versions below correspond to ComfyUI v0.37.0.
  # ══════════════════════════════════════════════════════════════════════════
  pins = {
    # -- built from GitHub source (fetchFromGitHub, tag = "v${version}") -----
    comfy-aimdo = {
      version = "0.5.5";
      hash    = "sha256-f5r2UgkWU49Y/sc9MBwlrmzaY3w4wcHJ0HgcFoVe3QY=";
    };
    comfy-kitchen = {
      version = "0.2.35";
      hash    = "sha256-ymNZ4uuM59cOf+neC6tfr+NXH9f7LpF9ml7gsYfB4Fk=";
    };

    # -- fetched from PyPI (fetchPypi) --------------------------------------
    comfyui-frontend-package = {
      version = "1.52.7";
      hash    = "sha256-XLKH2CthihdZjMrmQd1Wreh8paRN3IVKdyVtveKa2kM=";
    };
    comfyui-embedded-docs = {
      version = "0.5.12";
      hash    = "sha256-QKb7AIvnzFqcAUIlK9e93r1LBAczXennedlrFjoau0I=";
    };

    # workflow-templates is a meta-package: it pulls in the sub-packages
    # below at exactly these versions, so all of them move together.
    comfyui-workflow-templates = {
      version = "0.11.66";
      hash    = "sha256-PYTvWQ0u7MavD9lPHaEytxkdXOy35eze55qjd+D8tGI=";
    };
    comfyui-workflow-templates-core = {
      version = "0.3.357";
      hash    = "sha256-DCWykCQlJhIDvB+RCaLvvomn1OeKUO6nUbo15/O+uf4=";
    };
    comfyui-workflow-templates-json = {
      version = "0.1.92";
      hash    = "sha256-PHq+d5L7DdQFpFCL8hxp3O1qOiy6MELE3mqslDh5T+I=";
    };
    comfyui-workflow-templates-media-api = {
      version = "0.3.84";
      hash    = "sha256-a9XEluNo5eQN2H3+JfBm4k1X82AoiLo9+AATqI0GAlk=";
    };
    comfyui-workflow-templates-media-video = {
      version = "0.3.101";
      hash    = "sha256-dlLtmfubsAs52JBZGdyBUJIB4zXd4jqXNroTiRmQhHY=";
    };
    comfyui-workflow-templates-media-image = {
      version = "0.3.160";
      hash    = "sha256-iNz3STAsahL1uAPftGcktMiswx0RF87P9RZy2b2F6xg=";
    };
    comfyui-workflow-templates-media-other = {
      version = "0.3.229";
      hash    = "sha256-bi2wdS8sfOlPaoudRBpfnceLv6dldF8PnqyuzLzmk4U=";
    };
    comfyui-workflow-templates-media-assets-01 = {
      version = "0.1.47";
      hash    = "sha256-R8AUUFfROKiw1jr2b+kxwwkYJdVS6Cs48UCW59CVUFI=";
    };
    # NOTE: assets-02 does NOT exist in nixpkgs at all -- it is a new
    # upstream split.  It is defined from scratch further down rather than
    # overridden, but its pin lives here like everything else.
    comfyui-workflow-templates-media-assets-02 = {
      version = "0.1.3";
      hash    = "sha256-VqEUtsbYFoySosWw7RySa09aFVkAr3+Bzcf9Bf1flCQ=";
    };
  };
  # ══════════════════════════════════════════════════════════════════════════
  #  END OF PINS -- below here is mechanism.
  # ══════════════════════════════════════════════════════════════════════════

  # Read the version out of the source tree upstream generates, so the
  # derivation always reports what it actually built and ComfyUI itself is
  # never version-pinned in this file.
  comfyuiVersion =
    let
      lines   = lib.splitString "\n" (builtins.readFile "${src}/comfyui_version.py");
      verLine = lib.findFirst (lib.hasPrefix "__version__") null lines;
    in
    if verLine == null
    then "unstable"
    else lib.removeSuffix "\"" (lib.removePrefix "__version__ = \"" verLine);

  # Helper: repoint an existing nixpkgs python package at a new PyPI release.
  # `pypiName` is the underscored distribution name PyPI serves.
  bumpPypi =
    pkg: pin: pypiName:
    pkg.overridePythonAttrs (_: {
      inherit (pin) version;
      src = final.fetchPypi {
        pname   = pypiName;
        inherit (pin) version hash;
      };
    });

  # Helper: repoint an existing nixpkgs python package at a new GitHub tag.
  bumpGitHub =
    pkg: pin: { owner, repo, fetchSubmodules ? false }:
    pkg.overridePythonAttrs (_: {
      inherit (pin) version;
      src = final.fetchFromGitHub {
        inherit owner repo fetchSubmodules;
        tag  = "v${pin.version}";
        inherit (pin) hash;
      };
    });

  # The python package overrides, composed onto nixpkgs' own (which pin
  # torch/triton to cudaPackages_13 -- those MUST be preserved, they are what
  # makes this build usable on the RTX 5090 / sm_120).
  comfyPackageOverrides = pyfinal: pyprev: {
    comfy-aimdo = bumpGitHub pyprev.comfy-aimdo pins.comfy-aimdo {
      owner = "Comfy-Org";
      repo  = "comfy-aimdo";
    };

    comfy-kitchen = bumpGitHub pyprev.comfy-kitchen pins.comfy-kitchen {
      owner           = "Comfy-Org";
      repo            = "comfy-kitchen";
      fetchSubmodules = true;
    };

    comfyui-frontend-package =
      bumpPypi pyprev.comfyui-frontend-package
        pins.comfyui-frontend-package "comfyui_frontend_package";

    comfyui-embedded-docs =
      bumpPypi pyprev.comfyui-embedded-docs
        pins.comfyui-embedded-docs "comfyui_embedded_docs";

    comfyui-workflow-templates-core =
      bumpPypi pyprev.comfyui-workflow-templates-core
        pins.comfyui-workflow-templates-core "comfyui_workflow_templates_core";

    comfyui-workflow-templates-json =
      bumpPypi pyprev.comfyui-workflow-templates-json
        pins.comfyui-workflow-templates-json "comfyui_workflow_templates_json";

    comfyui-workflow-templates-media-api =
      bumpPypi pyprev.comfyui-workflow-templates-media-api
        pins.comfyui-workflow-templates-media-api
        "comfyui_workflow_templates_media_api";

    comfyui-workflow-templates-media-video =
      bumpPypi pyprev.comfyui-workflow-templates-media-video
        pins.comfyui-workflow-templates-media-video
        "comfyui_workflow_templates_media_video";

    comfyui-workflow-templates-media-image =
      bumpPypi pyprev.comfyui-workflow-templates-media-image
        pins.comfyui-workflow-templates-media-image
        "comfyui_workflow_templates_media_image";

    comfyui-workflow-templates-media-other =
      bumpPypi pyprev.comfyui-workflow-templates-media-other
        pins.comfyui-workflow-templates-media-other
        "comfyui_workflow_templates_media_other";

    comfyui-workflow-templates-media-assets-01 =
      bumpPypi pyprev.comfyui-workflow-templates-media-assets-01
        pins.comfyui-workflow-templates-media-assets-01
        "comfyui_workflow_templates_media_assets_01";

    # New upstream split -- no nixpkgs package to override, so define it.
    # Modelled on nixpkgs' assets-01: a pyproject package shipping static
    # assets, no test suite.
    comfyui-workflow-templates-media-assets-02 =
      let pin = pins.comfyui-workflow-templates-media-assets-02;
      in pyfinal.buildPythonPackage {
        pname   = "comfyui-workflow-templates-media-assets-02";
        inherit (pin) version;
        pyproject = true;

        src = final.fetchPypi {
          pname = "comfyui_workflow_templates_media_assets_02";
          inherit (pin) version hash;
        };

        build-system = [ pyfinal.setuptools ];

        # Ships static assets only.
        doCheck = false;
        pythonImportsCheck = [ "comfyui_workflow_templates_media_assets_02" ];

        meta = {
          description = "Media assets (part 2) for ComfyUI workflow templates";
          homepage    = "https://github.com/Comfy-Org/workflow_templates";
          license     = lib.licenses.mit;
        };
      };

    # The meta-package: new version, and assets-02 joins its dependencies.
    comfyui-workflow-templates =
      (bumpPypi pyprev.comfyui-workflow-templates
        pins.comfyui-workflow-templates "comfyui_workflow_templates")
      .overridePythonAttrs (old: {
        dependencies = (old.dependencies or [ ]) ++ [
          pyfinal.comfyui-workflow-templates-media-assets-02
        ];
      });
  };

  # Rebuild the python interpreter with nixpkgs' overrides AND ours.
  # `.override (old: ...)` gives access to nixpkgs' existing packageOverrides
  # so composeExtensions can keep the cudaPackages_13 torch/triton pins --
  # replacing them instead of composing would silently drop CUDA support.
  python = base.python.override (old: {
    self = python;
    packageOverrides =
      lib.composeExtensions
        (old.packageOverrides or (_: _: { }))
        comfyPackageOverrides;
  });

  # ComfyUI's runtime dependencies.
  #
  # Kept in sync with nixpkgs' pkgs/by-name/co/comfyui/package.nix. It has to
  # be restated here (not reused from `base.pythonEnv`) because that env was
  # already built against the OLD companion versions; the whole point is to
  # construct a new env from the overridden package set.
  #
  # If upstream adds a dependency, the `--quick-test-for-ci` boot test below
  # fails with a ModuleNotFoundError naming it -- add it here.
  appDependencies =
    ps: with ps;
    [
      aiohttp
      alembic
      av
      blake3
      comfy-aimdo
      comfy-angle
      comfy-kitchen
      comfyui-embedded-docs
      comfyui-frontend-package
      comfyui-workflow-templates
      einops
      filelock
      kornia
      numpy
      pillow
      psutil
      pydantic
      pydantic-settings
      pyopengl
      pyyaml
      requests
      safetensors
      scipy
      sentencepiece
      simpleeval
      spandrel
      sqlalchemy
      tokenizers
      torch
      torchaudio
      torchsde
      torchvision
      tqdm
      transformers
      yarl
    ];

  mkComfyui =
    { pname, withManager }:
    let
      pythonEnv = python.withPackages (
        ps: appDependencies ps ++ lib.optionals withManager [ ps.comfyui-manager ]
      );
    in
    final.stdenvNoCC.mkDerivation {
      inherit pname src;
      version = comfyuiVersion;

      nativeBuildInputs = [ final.makeBinaryWrapper ];

      # Upstream defaults --base-directory and the sqlite db into the source
      # tree, which is read-only in the store; this repoints them at
      # XDG_DATA_HOME so the systemd unit's StateDirectory works.
      patches = [ ./comfyui-runtime-paths.patch ];

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/comfyui $out/bin
        cp -r . $out/share/comfyui

        makeBinaryWrapper ${lib.getExe pythonEnv} $out/bin/comfyui \
          --add-flag "$out/share/comfyui/main.py" \
          --unset NIX_PYTHONPATH \
          --unset PYTHONPATH

        runHook postInstall
      '';

      # THE GATE.  `--quick-test-for-ci` boots the real server: node registry,
      # frontend resolution, model paths.  This is what proves the pinned
      # companion versions actually satisfy this ComfyUI -- it is how the
      # comfy_aimdo.storage break was found.  Do not disable it.
      #
      # nixpkgs additionally runs a `pip install --dry-run` against
      # requirements.txt; that is deliberately NOT used here because it
      # demands exact pins for packages nixpkgs resolves by attribute, and
      # would fail on version strings that are functionally fine.
      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck

        "$out"/bin/comfyui --help

        export XDG_DATA_HOME="$(mktemp -d)"
        "$out"/bin/comfyui --cpu --quick-test-for-ci

        runHook postInstallCheck
      '';

      passthru = { inherit python pythonEnv; };

      meta = base.meta // {
        version     = comfyuiVersion;
        description = base.meta.description + " (pinned ahead of nixpkgs)";
        changelog   =
          "https://github.com/Comfy-Org/ComfyUI/releases/tag/v${comfyuiVersion}";
      };
    };
in
{
  comfyui = mkComfyui {
    pname       = "comfyui";
    withManager = false;
  };

  # `--enable-manager` is a silent no-op unless comfyui_manager is importable:
  # upstream's main.py catches the ImportError, logs a hint, and turns the
  # flag back off.  This variant is what the service should use.
  comfyui-with-manager = mkComfyui {
    pname       = "comfyui-with-manager";
    withManager = true;
  };
}
