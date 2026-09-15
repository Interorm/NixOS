# Scrape / crawl / map / extract against the self-hosted Firecrawl on this
# host (modules/services/hermes/firecrawl.nix).  The port is read from that
# module rather than repeated, so moving the container cannot leave this
# pointing at a dead port.
#
# FIRECRAWL_API_URL is what makes it self-hosted: without it the server
# defaults to the cloud API and demands a key.  That instance runs with
# USE_DB_AUTHENTICATION=false, so no API key is set here -- the MCP server
# treats the key as optional once the URL is present.
{ pkgs, config, ... }: {
    command = "${pkgs.firecrawl-mcp}/bin/firecrawl-mcp";
    env.FIRECRAWL_API_URL =
        "http://127.0.0.1:${toString config.services.firecrawl.port}";
}
