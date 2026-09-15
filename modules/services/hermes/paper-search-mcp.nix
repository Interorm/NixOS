{ pkgs, lib }:

# paper-search-mcp is not in nixpkgs, so this packages it from the PyPI
# sdist directly (`pkgs.fetchPypi`) rather than reaching for `uvx`/`nix run`:
#   - uvx on this fleet fails outright (its downloaded portable CPython is a
#     dynamically-linked generic-linux build; NixOS can't exec it, and the
#     PyPI wheel's console-script shim also assumes `realpath`/`dirname` are
#     on PATH, which a minimal MCP server env doesn't guarantee).
#   - packaging it here pins the exact version, needs no network access at
#     server start, and matches how every other MCP server in mcps.nix is
#     wired (a plain `command` pointing at a /nix/store path).
#
# Verified 2026-09-15: builds clean with `nix-build`, and the built
# `bin/paper-search-mcp` responds to initialize + tools/list over stdio with
# 57 tools (search/download/read across arXiv, PubMed, bioRxiv, medRxiv,
# Semantic Scholar, Crossref, OpenAlex, DOAJ, Zenodo, HAL, SSRN, ...).
pkgs.python3Packages.buildPythonApplication rec {
  pname = "paper-search-mcp";
  version = "0.1.4";
  pyproject = true;

  src = pkgs.fetchPypi {
    pname = "paper_search_mcp"; # PyPI sdist filename uses underscores
    inherit version;
    hash = "sha256-NQGmJYQMqzQQ6ZDi8t9RvULKcwCHJFi/1Ev2vx8RiPg=";
  };

  build-system = with pkgs.python3Packages; [ hatchling ];

  dependencies = with pkgs.python3Packages; [
    requests
    feedparser
    mcp
    pypdf
    beautifulsoup4
    lxml
    httpx
    urllib3
  ];

  # fastmcp is declared upstream but never imported: the code uses
  # `mcp.server.fastmcp` (mcp<2 already ships this under that name).
  pythonRemoveDeps = [ "fastmcp" ];

  # No test suite ships in the sdist.
  doCheck = false;

  pythonImportsCheck = [ "paper_search_mcp" ];

  meta = with lib; {
    description = "MCP server for searching/downloading academic papers (arXiv, PubMed, bioRxiv, ...)";
    homepage = "https://github.com/openags/paper-search-mcp";
    license = licenses.mit;
    mainProgram = "paper-search-mcp";
  };
}
