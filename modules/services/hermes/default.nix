{
    ...
}: {
    # The MCP fleet and the per-account/profile declarations live under
    # top-level hermes/ -- this file stays the service's IMPLEMENTATION
    # (option schema + systemd/home-manager wiring), imported once per host
    # alongside hermes/default.nix.
    imports = [
        ./hermes.nix
        ./speaches.nix

        ./firecrawl.nix
        ./docling.nix
    ];
}