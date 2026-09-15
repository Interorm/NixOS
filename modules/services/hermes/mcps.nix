{
    config,
    lib,
    pkgs,
    inputs,
    ...
}: let
    cfg = config.services.hermes-agents;

    # Not in nixpkgs -- packaged from the PyPI sdist. See the file for why
    # this isn't just `uvx paper-search-mcp`.
    paper-search-mcp = pkgs.callPackage ./paper-search-mcp.nix { };
in {
    config = lib.mkIf cfg.enable {
        environment.systemPackages = with pkgs; [
            mcp-nixos 
            github-mcp-server
            firecrawl-mcp
            paper-search-mcp
        ];

        services.hermes-agents.mcpServers = {
            github = {
                command = "${pkgs.github-mcp-server}/bin/github-mcp-server";
                args = [ "stdio" ];
                env.GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}";
            };

            nixos = {
                command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
            };

            # Scrape / crawl / map / extract against the self-hosted Firecrawl
            # on this host (modules/services/hermes/firecrawl.nix).  The port
            # is read from that module rather than repeated, so moving the
            # container cannot leave this pointing at a dead port.
            #
            # FIRECRAWL_API_URL is what makes it self-hosted: without it the
            # server defaults to the cloud API and demands a key.  That
            # instance runs with USE_DB_AUTHENTICATION=false, so no API key is
            # set here -- the MCP server treats the key as optional once the
            # URL is present.
            firecrawl = {
                command = "${pkgs.firecrawl-mcp}/bin/firecrawl-mcp";
                env.FIRECRAWL_API_URL =
                    "http://127.0.0.1:${toString config.services.firecrawl.port}";
            };

            # Up-to-date, version-specific library docs + code examples.
            context7 = {
                url = "https://mcp.context7.com/mcp";
            };
            # Ask questions about any public GitHub repo (Devin's DeepWiki).
            deepwiki = {
                url = "https://mcp.deepwiki.com/mcp";
            };

            # Search/download/read academic papers (arXiv, PubMed, bioRxiv,
            # medRxiv, Semantic Scholar, Crossref, OpenAlex, DOAJ, Zenodo,
            # HAL, SSRN, ...). All sources work keyless; CORE/DOAJ/Unpaywall
            # accept an optional key via env for higher rate limits -- add
            # one later as an agenix secret if this gets rate-limited.
            paper-search = {
                command = "${paper-search-mcp}/bin/paper-search-mcp";
            };
        };
    };
}
