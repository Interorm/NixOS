{
    ...
}: {
    # Configuration side of the Hermes fleet, as opposed to
    # modules/services/hermes/ which is the service's IMPLEMENTATION (option
    # schema, systemd/home-manager wiring).
    #
    # Layout:
    #   fleet.nix    host-wide settings (speech, docling, gateway topology)
    #   lib.nix      auto-discovers mcp/ + profiles/ into two attrsets
    #   mcp/         one file per MCP server, named and reused by snippet
    #   profiles/    one file per role preset (orchestrator, nixos, ...)
    #   users/       one file per Unix account, grafting the above together
    #
    # Adding an MCP server or a profile preset is a single new file in
    # mcp/ or profiles/ -- lib.nix discovers it with readDir, so there is no
    # registration list to keep in sync.  Only users/ needs an import line
    # here, because each new account is also a new Unix user and agenix
    # secret.
    imports = [
        ./fleet.nix

        ./users/karl.nix
        ./users/joni.nix
        ./users/nana.nix
        ./users/sabine.nix
    ];
}
