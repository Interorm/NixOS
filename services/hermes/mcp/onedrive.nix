{ pkgs, ... }:
let
    bin = pkgs.writeShellScriptBin "onedrive-mcp" ''
        exec ${pkgs.python3}/bin/python3 ${pkgs.copyPathToStore ./onedrive/mcp_server.py} "$@"
    '';
in {
    command = "${bin}/bin/onedrive-mcp";
    env.ONEDRIVE_CLIENT_ID = "\${ONEDRIVE_CLIENT_ID}";
    args = [ ];
    meta = {
        description = "MCP for accessing onedrive clients via the Microsoft Graph API. Based on app, full read access and write acces in app-folder";
        requires.envVars = [ "ONEDRICE_CLIENT_ID" ];
    };
}
