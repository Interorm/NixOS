# OneDrive (Microsoft Graph) MCP server — zero-dependency, Python stdlib only.
#
# All the code now lives in this repo under hermes/mcp/onedrive/ (the parent
# coder card moved it out of ~/.hermes/bin/ so the flake is the single source
# of truth).  mcp_server.py is the entry point; the other files (api_cli.py,
# login.py, lock_test.py, ...) are standalone CLIs/tests the server does NOT
# import at runtime, so we bundle only what the server needs.
#
# Rebuild-proof: the flake checkout is mutable on `git pull`, so nothing at
# runtime may point at a checkout or home path.  Instead the server is shipped
# as a store-path application:
#   * copyPathToStore copies the EXACT repo file into the store (content-
#     addressed, byte-for-byte) -- the content comes from the flake's git
#     revision, so a rebuild re-derives the right version declaratively.
#   * writeShellScriptBin wraps it as bin/onedrive-mcp with the interpreter
#     pinned in, so the command does not depend on what lands on the
#     gateway's PATH.
#
# NOTE: this pinned nixpkgs no longer ships `pkgs.python3.application` (the
# 2026 python rewrite dropped it), so we build the application from the native
# `copyPathToStore` + `writeShellScriptBin` primitives instead -- same shape
# (a store path exposing bin/onedrive-mcp), no new packages or flake inputs.
#
# Token: ~/.hermes/onedrive_token.json (0600, self-refreshing), overridable via
# the ONEDRIVE_TOKEN env var (per-account isolation; the lock sidecar derives
# from the token path).  Client id: ONEDRIVE_CLIENT_ID, delivered to the server
# through the agent's agenix-encrypted ~/.hermes/.env (Hermes loads it and
# resolves ${VAR} in MCP configs); needed only for the self-login flow.  See
# hermes/mcp/onedrive/README.md.
#
# Security model: reads/searches cover the whole drive (Files.Read); writes are
# API-confined by Microsoft to the app folder (Files.ReadWrite.AppFolder) -- an
# out-of-scope write is rejected with 404 itemNotFound at the Graph API.
{ pkgs, ... }:
let
    bin = pkgs.writeShellScriptBin "onedrive-mcp" ''
        exec ${pkgs.python3}/bin/python3 ${pkgs.copyPathToStore ./onedrive/mcp_server.py} "$@"
    '';
in {
    command = "${bin}/bin/onedrive-mcp";
    args = [ ];
}
