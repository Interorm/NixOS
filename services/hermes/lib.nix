# hermes/lib.nix -- the snippet registry.
#
# Auto-discovers every snippet under ./mcp/ and ./profiles/ and returns them
# as two attrsets, so a user file can graft a fleet together by name:
#
#     let inherit (import ../lib.nix { inherit pkgs config lib; }) mcp profiles;
#     in {
#       services.hermes-agents.agents.karl = {
#         mcpServers = { inherit (mcp) github nixos; };
#         profiles   = { inherit (profiles) nixos researcher; };
#       };
#     }
#
# readDir, not a hand-maintained list: dropping in hermes/mcp/foo.nix makes
# `mcp.foo` exist with no registration step anywhere.  The attribute name is
# the filename without ".nix".
#
# `skills` is the same idea for repo-shipped SKILL.md trees under ./skills/:
# dropping in hermes/skills/foo/SKILL.md makes `skills.foo` exist as a store
# path.  See the comment on `skills` below for how it is consumed.
#
# Every snippet is a FUNCTION of module args (`{ pkgs, config, ... }:`), even
# when it ignores them -- uniformity means a snippet can later start reading
# `config.services.<x>.port` without its call sites changing.  They are
# applied here, so callers see plain data.
#
# WHY A `let`-BOUND IMPORT AND NOT A MODULE ARGUMENT: secrets/secrets.nix
# plain-`import`s each users/<name>.nix with dummy args (pkgs/config/lib =
# null) to read `sshKeys` without evaluating NixOS at all.  Nix is lazy, so
# as long as `mcp`/`profiles` are only *bound* (not forced) on that path,
# those nulls are never touched and the secrets machinery keeps working.
# Making the registry a module argument instead would force it eagerly and
# break `agenix -e`.
{ pkgs, config, lib, ... }:

let
    # Apply every *.nix in `dir` to the module args, keyed by basename.
    # Anything that is not a .nix file (a README, an editor swapfile) is
    # ignored rather than erroring, so the directory stays browsable.
    loadDir = dir:
        let
            entries = builtins.readDir dir;
            isSnippet = name: type:
                type == "regular" && lib.hasSuffix ".nix" name;
            snippets = lib.filterAttrs isSnippet entries;
        in lib.mapAttrs' (name: _:
            lib.nameValuePair
                (lib.removeSuffix ".nix" name)
                (import (dir + "/${name}") { inherit pkgs config lib; })
        ) snippets;

    mcp = loadDir ./mcp;

    # Profile snippets get the MCP registry too: a profile preset's whole
    # point is to pick its own MCP servers, and it should name them
    # (`inherit (mcp) firecrawl;`) rather than restating command lines.
    profiles = let
        entries = builtins.readDir ./profiles;
        isSnippet = name: type: type == "regular" && lib.hasSuffix ".nix" name;
    in lib.mapAttrs' (name: _:
        lib.nameValuePair
            (lib.removeSuffix ".nix" name)
            (import (./profiles + "/${name}") { inherit pkgs config lib mcp; })
    ) (lib.filterAttrs isSnippet entries);

    # Repo-shipped skills: one subdirectory per skill under ./skills/, each
    # holding a SKILL.md (plus optional references/, scripts/, ...).  Discovered
    # with readDir exactly like ./mcp, so adding hermes/skills/foo/SKILL.md makes
    # `skills.foo` exist with no registration step.
    #
    # Each value is a STORE PATH containing that one skill, shaped
    # `<store-path>/<name>/SKILL.md` -- the layout Hermes' external-skills walker
    # expects (it rglobs for SKILL.md, so the skill's own directory level must be
    # present).  Consumed via `settings.skills.external_dirs`, which is the
    # sanctioned read-only hatch: modules/services/hermes/hermes.nix deliberately
    # does NOT manage ~/.hermes/skills/ so that a rebuild cannot wipe hand- or
    # agent-authored skills.  Never copy one of these into that tree.
    #
    # LAZINESS, same as mcp/profiles: this is a `let` binding inside the
    # registry, and `pkgs` is only forced when a caller actually reads a skill
    # path.  secrets/secrets.nix plain-imports hermes/users/*.nix with
    # `pkgs = null` and must keep working, so nothing on that path may force
    # this -- do not turn it into a module argument and do not make any user
    # file force it unconditionally.
    skills = let
        entries = builtins.readDir ./skills;
        isSkill = name: type:
            type == "directory" && builtins.pathExists (./skills + "/${name}/SKILL.md");
    in lib.mapAttrs (name: _:
        pkgs.runCommand "hermes-skill-${name}" { } ''
            mkdir -p "$out"
            cp -r ${./skills + "/${name}"} "$out/${name}"
        ''
    ) (lib.filterAttrs isSkill entries);
in {
    inherit mcp profiles skills;
}
