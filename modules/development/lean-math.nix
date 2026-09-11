{
    config,
    lib,
    pkgs,
    inputs,
    ...
}: let
    # The shared Lean project.  Owned by the `lean-math` group and group-
    # writable, so every agent in that group (karl, joni, ...) reads and builds
    # against the SAME project and the SAME olean cache.  That is what makes
    # "Lean for multiple users" cheap: one `lake exe cache get` warms the oleans
    # for everyone; the heavy mathlib oleans are fetched from the community
    # artifact cache at first use, not compiled locally.
    #
    # The MCP server (see modules/services/hermes/mcps.nix) points at this dir
    # with `--lean-project-path`.  On the first Lean tool call it runs
    # `lake clean` -> `lake exe cache get` -> `lake build` here.  Concurrent
    # builds by two agents are guarded by lake's own file locks (the loser
    # retries); for a two-user homelab that contention is negligible.
    projectPath = config.services.lean-math.projectPath;

    # Must match the toolchain nixpkgs' `lean4` provides, so the community olean
    # cache hit is exact.  nixpkgs.lean4 is 4.30.0.
    toolchain = "leanprover/lean4-v4.30.0";
in {
    options.services.lean-math = {
        enable = lib.mkEnableOption "a shared Lean 4 + Mathlib project for the Hermes agents";

        projectPath = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/lean-math";
            description = "Where the shared Lean lake project lives. Pick a persistent mount, not /tmp.";
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

    config = lib.mkMerge [
        # Group + the shared, group-writable project dir.
        {
            users.groups."lean-math" = { };

            systemd.tmpfiles.rules = [
                # 0775 root:lean-math -> group members (the agents) can create
                # the .lake build cache and oleans inside it.
                "d ${projectPath} 0775 root lean-math - -"
            ];
        }

        # The agents join the group so they can read/write the shared project.
        # Merges with the agent users hermes.nix already defines (attrsOf
        # deep-merge), so extraGroups accumulates rather than clobbering.
        {
            users.users = lib.listToAttrs (map (u: {
                name = u;
                value = { extraGroups = [ "lean-math" ]; };
            }) config.services.lean-math.users);
        }

        # Seed the minimal lake project once (idempotent): lean-toolchain,
        # lakefile.toml (mathlib dep), and a demo theorem.  The MCP server does
        # the cache-get + build later; this just lays down the source.
        {
            system.activationScripts.lean-math = {
                text = ''
                    set -e
                    if [ -f ${projectPath}/lakefile.toml ]; then
                        echo "lean-math: shared project already in place at ${projectPath}"
                    else
                        echo "lean-math: seeding shared Lean project at ${projectPath}"
                        printf '%s\n' '${toolchain}' > ${projectPath}/lean-toolchain

                        cat > ${projectPath}/lakefile.toml <<EOF
name    = "lean-math"
lakeDir = ".lake"

[[require]]
name = "mathlib"
src  = git "https://github.com/leanprover-community/mathlib4"
  { rev = "v4.30.0" }
EOF

                        mkdir -p ${projectPath}/Source
                        cat > ${projectPath}/Source/Main.lean <<EOF
import Mathlib

/-
Demo goal: warms the cache and gives the agents something to verify.
-/
example (a b : Nat) (h : a = b) : a ≤ b :=
  le_of_eq h
EOF

                        chown -R root:lean-math ${projectPath}
                        chmod -R g+w ${projectPath}
                    fi
                '';
            };
        }
    ];
}
