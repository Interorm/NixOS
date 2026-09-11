{
    config,
    lib,
    pkgs,
    inputs,
    ...
}: let
    cfg = config.services.lean-math;

    projectPath = cfg.projectPath;
    cachePath = cfg.cachePath;

    # Toolchain used by the shared project.
    #
    # NOTE: `lean`/`lake` on this host come from *elan* (the Lean version
    # multiplexer), not from `pkgs.lean4`.  elan reads `lean-toolchain` and
    # fetches that exact toolchain on demand, so this pin is what decides the
    # Lean version -- `pkgs.lean4.version` is irrelevant here.
    #
    # It MUST match the mathlib `rev` below, because the community olean cache
    # is only valid for the toolchain mathlib was built with.  Verified
    # 2026-09-11: v4.33.1 + mathlib v4.33.1 gives a full 8690/8690 cache hit,
    # so no local mathlib compile is ever needed.
    toolchain = "leanprover/lean4:v4.33.1";
    mathlibRev = "v4.33.1";

    # Seed files are built as store paths and copied in, rather than emitted
    # from heredocs inside the script.  Nix's '' strings strip only the COMMON
    # indentation, so an indented `EOF` terminator stays indented and the
    # heredoc never closes -- writeText sidesteps that class of bug entirely.
    #
    # NOTE: this is lakefile.TOML.  An earlier revision emitted
    # `src = git "..." { rev = "..." }`, which is lakefile.LEAN syntax and is
    # not parseable as TOML, so the seeded project could never resolve mathlib.
    # The scope/rev form below is what `lake new <name> math` itself generates.
    lakefile = pkgs.writeText "lean-math-lakefile.toml" ''
        name = "lean-math"
        defaultTargets = ["LeanMath"]

        [[require]]
        name = "mathlib"
        scope = "leanprover-community"
        rev = "${mathlibRev}"

        [[lean_lib]]
        name = "LeanMath"
    '';

    smokeTest = pkgs.writeText "LeanMathBasic.lean" ''
        import Mathlib

        /-! Smoke test: proves the shared olean cache is live. -/

        -- `ring` exists only with Mathlib, not in core Lean.
        example (a b : ℤ) : (a + b) ^ 2 = a ^ 2 + 2 * a * b + b ^ 2 := by ring

        example : Irrational (Real.sqrt 2) := irrational_sqrt_two
    '';
in {
    options.services.lean-math = {
        enable = lib.mkEnableOption "a shared Lean 4 + Mathlib project for the Hermes agents";

        projectPath = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/lean-math";
            description = ''
                Where the shared Lean lake project lives.  Must be a persistent
                mount, never /tmp: the resolved mathlib source plus its oleans
                are ~7.5 GB and are expensive to recreate.
            '';
        };

        cachePath = lib.mkOption {
            type = lib.types.str;
            default = "/var/cache/mathlib";
            description = ''
                Shared mathlib artifact (.ltar) cache, exported to the agents as
                MATHLIB_CACHE_DIR.  Without this each agent keeps a private
                ~440 MB copy under its own ~/.cache/mathlib; pointing them at
                one directory means the first `lake exe cache get` warms the
                oleans for everybody.
            '';
        };

        users = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "karl" "joni" ];
            description = ''
                Agent user names given access to the shared project.  Each is
                added to the `lean-math` group so they can read and build the
                shared olean cache.  Usually the same as the
                `services.hermes-agents.agents` names.
            '';
        };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
        {
            users.groups."lean-math" = { };

            systemd.tmpfiles.rules = [
                # 2775: the setgid bit is load-bearing.  Without it, files that
                # karl creates inside the project are owned by group `karl`,
                # and joni -- also in `lean-math` -- cannot write them, which
                # defeats the whole point of a shared build tree.  setgid makes
                # every new file inherit the `lean-math` group instead.
                "d ${projectPath} 2775 root lean-math - -"
                "d ${cachePath}   2775 root lean-math - -"

                # setgid fixes the *group*; default ACLs fix the *mode*, so
                # files land group-writable rather than relying on each agent's
                # umask (lake does not set one).
                "A ${projectPath} - - - - d:group:lean-math:rwx"
                "A ${cachePath}   - - - - d:group:lean-math:rwx"
            ];

            # Both the seeding service and the agents' own interactive
            # `lake` invocations must agree on the cache location.
            environment.variables.MATHLIB_CACHE_DIR = cachePath;
        }

        # The agents join the group so they can read/write the shared project.
        # Merges with the agent users hermes.nix already defines (attrsOf
        # deep-merge), so extraGroups accumulates rather than clobbering.
        {
            users.users = lib.listToAttrs (map (u: {
                name = u;
                value = { extraGroups = [ "lean-math" ]; };
            }) cfg.users);
        }

        # Seed + warm the shared project.
        #
        # This was previously a `system.activationScripts` entry, which raced:
        # activation ran the chown before systemd-tmpfiles had created the
        # directory with the right owner, leaving /var/lib/lean-math as
        # `nobody:nogroup` and unwritable by the agents, with no lakefile.toml
        # ever seeded.  A oneshot service ordered explicitly After tmpfiles and
        # the network cannot race, is re-runnable (`systemctl start
        # lean-math-seed`), and logs to the journal where failures are visible.
        {
            systemd.services.lean-math-seed = {
                description = "Seed and warm the shared Lean 4 + Mathlib project";
                wantedBy = [ "multi-user.target" ];
                after = [ "systemd-tmpfiles-setup.service" "network-online.target" ];
                wants = [ "network-online.target" ];

                path = [ pkgs.elan pkgs.git pkgs.curl pkgs.gnutar pkgs.gzip pkgs.zstd ];

                environment = {
                    MATHLIB_CACHE_DIR = cachePath;
                    # elan needs a writable home for the downloaded toolchain.
                    ELAN_HOME = "${projectPath}/.elan";
                };

                serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    User = "root";
                    Group = "lean-math";
                    UMask = "0002"; # keep everything group-writable
                    WorkingDirectory = projectPath;
                    # Resolving + fetching mathlib on a cold cache is slow.
                    TimeoutStartSec = "60min";
                };

                script = ''
                    set -euo pipefail

                    if [ ! -f lakefile.toml ]; then
                        echo "lean-math: seeding shared Lean project at ${projectPath}"

                        printf '%s\n' '${toolchain}' > lean-toolchain

                        # NOTE: this is lakefile.TOML.  The previous revision
                        # emitted `src = git "..." { rev = "..." }`, which is
                        # lakefile.LEAN syntax and is not parseable as TOML --
                        # the seeded project could never have resolved mathlib.
                        # The scope/rev form used by `lakefile` above is what
                        # `lake new <x> math` itself generates, and is known-good.
                        install -m 0664 ${lakefile} lakefile.toml

                        mkdir -p LeanMath
                        install -m 0664 ${smokeTest} LeanMath/Basic.lean

                        printf 'import LeanMath.Basic\n' > LeanMath.lean
                    else
                        echo "lean-math: project already seeded at ${projectPath}"
                    fi

                    # Resolve deps.  mathlib's post-update hook pulls the
                    # prebuilt oleans from the community cache automatically.
                    lake update

                    # Belt and braces: explicit cache fetch in case the hook was
                    # skipped (already-resolved manifest).  Non-fatal -- a cache
                    # miss only means a slower `lake build`.
                    lake exe cache get || echo "lean-math: cache get failed, falling back to local build"

                    lake build

                    # tmpfiles' setgid + ACL cover files created from here on;
                    # this fixes up anything laid down before those applied.
                    chgrp -R lean-math ${projectPath} ${cachePath} || true
                    chmod -R g+rwX  ${projectPath} ${cachePath} || true

                    echo "lean-math: shared project ready at ${projectPath}"
                '';
            };
        }
    ]);
}
