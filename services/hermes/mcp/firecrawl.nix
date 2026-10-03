{ pkgs, config, ... }: {
    command = "${pkgs.firecrawl-mcp}/bin/firecrawl-mcp";
    env.FIRECRAWL_API_URL =
        "http://127.0.0.1:${toString config.services.firecrawl.port}";
}
