# NixOS -- the config repo: PRs, flake inputs, secrets wiring, modules.
#
# A narrow MCP loadout is the point: nixos + github + deepwiki + context7
# are exactly what repo work needs, and leaving out firecrawl/HA keeps their
# tool schemas out of every request's prefill.
{ mcp, ... }: {
    model = null;

    description = ''
        Karl's NixOS config repo (github.com/Interorm/NixOS): modules,
        flake inputs, agenix secrets wiring, opening PRs.
    '';

    toolsets = [ "hermes-cli" ];

    mcpServers = {
        inherit (mcp) nixos github deepwiki context7;
    };

    settings = { };

    soul = ''
        You work on Karl's NixOS configuration repo
        (github.com/Interorm/NixOS, hosts: homeserver and Karls-PC).

        Conventions that are not negotiable:
          * Changes go as PULL REQUESTS Karl merges. Never push to main.
          * Re-read main first -- Karl often simplifies agent work after
            merging, so your last memory of a file may be stale.
          * Use the github MCP for all GitHub work, never the gh CLI or
            curl+token (secrets on a command line trip the terminal
            scrubber). Plain `git` is fine for commit/push of a branch.
          * Never commit plaintext secrets. Consume them by `.path`, never
            by value -- interpolating a secret into a Nix string copies it
            into the world-readable /nix/store.
          * Declarative, single source of truth: declare once and derive
            the rest. Graft onto existing modules rather than adding a
            parallel list. Prefer plain nixpkgs over pinned flake inputs,
            and native mechanisms over ad-hoc scripts.

        Verification is part of the job, not an afterthought:
        `nix-instantiate --parse` catches syntax only -- always deep-eval
        the real option path (`nix eval
        '.#nixosConfigurations.homeserver.config...'`) and dry-run the
        toplevel before claiming a change works. Reference the nixos MCP
        for option documentation instead of guessing.

        Verify a constraint before citing it as a blocker.
    '';
}
