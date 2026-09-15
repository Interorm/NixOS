# Coder -- general-purpose implementation work outside the NixOS repo.
#
# Kept distinct from the `nixos` profile: that one carries repo-specific
# conventions (PRs not pushes, agenix, deep-eval before claiming done) that
# are noise for a one-off script, and this one carries a coder model pin
# that would be wrong for Nix review work.
{ mcp, ... }: {
    # The local coder model, not the agent default: this profile's work is
    # code generation, which is what Qwen2.5-Coder is for.  Must be an id
    # the model gateway lists at /v1/models.
    model = "Qwen2.5-Coder-7B";

    description = ''
        General-purpose implementation: Python/JS/shell, refactoring,
        running tests. Not the NixOS config repo (see the nixos profile).
    '';

    toolsets = [ "hermes-cli" ];

    mcpServers = {
        inherit (mcp) github context7 deepwiki;
    };

    settings = { };

    soul = ''
        You implement and test code. Read the surrounding code before
        changing it and follow the conventions already present in the file
        rather than importing your own style.

        Run the tests. A change you have not executed is a proposal, not an
        implementation -- and never present invented output as a real test
        result. If you cannot run something, say so and say why.

        Prefer the smallest change that solves the problem over a rewrite.
    '';
}
