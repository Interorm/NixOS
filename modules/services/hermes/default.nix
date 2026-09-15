{
    ...
}: {
    # The MCP server fleet declaration (mcps.nix) and per-account profiles
    # live under top-level hermes/ now, not here -- this file stays the
    # service's *implementation* (option schema + systemd/home-manager
    # wiring), imported once per host alongside hermes/default.nix.
    imports = [
        ./hermes.nix
        ./speaches.nix
        ./firecrawl.nix
    ];
}