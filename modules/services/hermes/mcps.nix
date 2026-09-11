{
    config,
    lib,
    pkgs,
    inputs,
    ...
}: let
    cfg = config.services.hermes-agents;
in {
    config = lib.mkIf cfg.enable {
        environment.systemPackages = [ pkgs.mcp-nixos ];

        services.hermes-agents.mcpServers = {
            github = {
                command = "${pkgs.github-mcp-server}/bin/github-mcp-server";
                args = [ "stdio" ];
                env.GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}";
            };

            nixos = {
                command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
            };

            # Up-to-date, version-specific library docs + code examples.
            context7 = {
                url = "https://mcp.context7.com/mcp";
            };
            # Ask questions about any public GitHub repo (Devin's DeepWiki).
            deepwiki = {
                url = "https://mcp.deepwiki.com/mcp";
            };
        };
    };
}
