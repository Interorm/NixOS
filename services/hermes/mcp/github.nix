{ pkgs, ... }: {
    command = "${pkgs.github-mcp-server}/bin/github-mcp-server";
    args = [ "stdio" ];
    env.GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}";
    meta = {
        description = "MCP for accessing GitHub repositories.";
        requires.envVars = [ "GITHUB_TOKEN" ];
    };
}
