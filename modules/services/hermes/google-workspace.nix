{
    lib,
    pkgs,
    ...
}: let
    # Agents that get the Google Workspace toolchain.  Keep in sync with
    # hosts/*/hermes_profiles.nix; listed here rather than read from
    # `config.services.hermes-agents.agents` because defining that option in
    # terms of itself is infinite recursion.
    users = [ "karl" "joni" ];

    # The google-workspace skill shells out to `python` and imports
    # google.auth / google_auth_oauthlib / googleapiclient.  On NixOS there is
    # no pip install into a read-only store, so the interpreter has to carry
    # the libraries with it.  All three are prebuilt in nixpkgs -- this is a
    # download, not a compile.
    googlePython = pkgs.python3.withPackages (ps: with ps; [
        google-auth
        google-auth-oauthlib
        google-api-python-client
    ]);
in {
    # Per-agent `extraPackages` is a submodule option, so defining it from
    # this separate module merges with whatever hermes_profiles.nix sets --
    # no need to touch that file.
    services.hermes-agents.agents = lib.listToAttrs (map (u: {
        name = u;
        value.extraPackages = [ googlePython ];
    }) users);
}
