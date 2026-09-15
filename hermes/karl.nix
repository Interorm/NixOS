{
    pkgs,
    ...
}: {
    # Karl's Hermes agent account.  See ./fleet.nix for host-wide settings
    # and ./mcps.nix for the shared MCP server fleet; this file is scoped to
    # karl's identity, secrets wiring (sshKeys), ports, and profiles.
    services.hermes-agents.agents.karl = {
        dashboard.port = 9090;
        mobile.enable = true;

        sshKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
        ];
        apiServerPort = 9190;

        extraPackages = with pkgs; [
            elan
            uv
            nodejs
            ripgrep
        ];
        googleWorkspace.enable = true;

        soul = ''
            You are Karl's personal assistant running on his homelab. Be concise but thorough.  
            ALWAYS use MCPs if they seem relevant, prefer MCPs over own scripts or knowledge.
            You have access to the internet via web search, a paper search mcp and firecrawl. When asked to perform research, use firecrawl and the paper search mcp for real results.
            You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.
        '';

        # Top-level profile (the one karl actually chats with day to day)
        # opts into the kanban toolset directly -- note this is the
        # top-level `toolsets` config.yaml key specifically, the one the
        # kanban tool-availability gate reads (hermes-agent issue #83042),
        # not the `platform_toolsets` key `hermes tools enable` writes.
        # `orchestrator_profile` routes assignee-less kanban_create calls to
        # the orchestrator profile below instead of falling back to
        # whichever profile happens to be chatting.
        settings = {
            toolsets = [ "hermes-cli" "kanban" ];
            kanban.orchestrator_profile = "orchestrator";
        };

        # Declarative Kanban roster: one orchestrator profile that
        # decomposes/routes work, plus specialist workers it can assign
        # cards to.  All of these share karl's ONE gateway process,
        # HERMES_HOME and ~/.hermes/kanban.db (see the `profiles` option in
        # modules/services/hermes/hermes.nix) -- this is per-account, so it
        # does not give joni/nana/sabine visibility into karl's board, and
        # karl gets no visibility into theirs.
        #
        # One-time after a rebuild that adds/renames a profile:
        #   sudo -iu karl hermes kanban init   # creates kanban.db if absent
        profiles = {
            orchestrator = {
                description = ''
                    Routes and decomposes goals into Kanban cards across
                    karl's other profiles (researcher, coder). Does not do
                    the work itself -- assigns and reviews.
                '';
                toolsets = [ "kanban" ];
            };

            researcher = {
                description = ''
                    Web research, document analysis, fact-checking, citation
                    gathering.
                '';
                toolsets = [ "hermes-cli" ];
            };

            coder = {
                description = ''
                    Nix/Python/JS implementation work: refactoring, running
                    tests, opening PRs against Karl's repos.
                '';
                toolsets = [ "hermes-cli" ];
            };
        };
    };
}
