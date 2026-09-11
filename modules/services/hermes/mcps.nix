{
    config,
    lib,
    pkgs,
    inputs,
    ...
}: let
    cfg = config.services.hermes-agents;
in {
    # One place to declare every MCP server the Hermes agents get.  Imported by
    # modules/services/hermes/default.nix, so it only applies where that module
    # is loaded (the homeserver).  It feeds the fleet-wide
    # `services.hermes-agents.mcpServers`, which hermes.nix merges under each
    # agent's own `mcpServers` -- so every agent gets these unless it overrides
    # one by name.
    #
    # Two shapes, matching Hermes' own mcpServers option:
    #   stdio : command / args / env      (a binary we run locally)
    #   http  : url / headers             (a hosted endpoint)
    # Secrets go in the agent's ${cfg.secretsDir}/<name>.env and are referenced
    # as ''${VAR} -- Hermes resolves them at runtime, so nothing secret lands
    # in the Nix store.
    config = lib.mkIf cfg.enable {
        services.hermes-agents.mcpServers = {
            # --- Local stdio servers ---------------------------------------

            # NixOS / Home Manager / nix-darwin introspection: search 130k+
            # packages, 23k+ NixOS options, FlakeHub, Noogle, wiki.  Built from
            # source via its flake (pythonRelaxDeps), so no network at runtime.
            nix = {
                command = "${inputs.mcp-nixos.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/mcp-nixos";
                connect_timeout = 60;
            };

            # Lean 4 + Mathlib formal maths.  Shared project dir (see
            # modules/development/lean-math.nix) so karl and joni reuse one
            # olean cache.  The first tool call triggers `lake exe cache get`
            # + `lake build` inside the server, hence the generous timeout.
            lean-math = {
                command = "${inputs.lean-lsp-mcp.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/lean-lsp-mcp";
                args = [ "--lean-project-path" config.services.lean-math.projectPath ];
                connect_timeout = 300;
                timeout = 600;
            };

            # --- Hosted HTTP servers (no key) ------------------------------

            # Up-to-date, version-specific library docs + code examples.
            context7 = {
                url = "https://mcp.context7.com/mcp";
            };

            # Ask questions about any public GitHub repo (Devin's DeepWiki).
            deepwiki = {
                url = "https://mcp.deepwiki.com/mcp";
            };

            # Ping / traceroute / DNS / HTTP from global probes (jsDelivr).
            # Free tier needs no auth; an OAuth token can be added later via
            # headers.Authorization = ''${GLOBALPING_TOKEN}.
            globalping = {
                url = "https://mcp.globalping.dev/mcp";
            };
        };
    };
}
