{
    ...
}: {
    # Configuration side of the Hermes fleet, as opposed to
    # modules/services/hermes/ which is the service's implementation
    # (option schema, systemd/home-manager wiring).  Split by concern so
    # each account's identity/secrets/profiles live in their own reviewable
    # file -- a prerequisite for later automation that lets each person
    # propose changes to their own file without touching anyone else's.
    imports = [
        ./fleet.nix
        ./mcps.nix
        ./karl.nix
        ./joni.nix
        ./nana.nix
        ./sabine.nix
    ];
}
