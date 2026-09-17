# OneDrive (Microsoft Graph) MCP server — zero-dependency, Python stdlib only.
# No pip packages, no build, no environment variable, no client secret: the
# server reads a self-refreshing token from ~/.hermes/onedrive_token.json
# (0600, user-owned, survives rebuilds like the rest of ~/.hermes), the same
# persistence pattern as ~/.hermes/google_token.json.
#
# Security model: reads/searches cover the whole drive (Files.Read); writes
# are API-confined by Microsoft to the app folder (Files.ReadWrite.AppFolder)
# — an out-of-scope write is rejected with 404 itemNotFound at the Graph API.
#
# stdlib only, so the host's default interpreter is enough; pinned to the
# absolute store path (like the other snippets) so it is rebuild-proof and
# does not depend on what happens to land on the gateway's PATH. The script
# path is absolute because ~/.hermes/bin is not on PATH; the script itself
# lives under ~/.hermes/bin/, which a rebuild does not touch.
{ pkgs, ... }: {
    command = "${pkgs.python3}/bin/python3";
    args = [ "/home/karl/.hermes/bin/onedrive_mcp.py" ];
}
