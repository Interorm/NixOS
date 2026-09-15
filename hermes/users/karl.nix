{ pkgs, config, lib, ... }:

# The snippet registry.  Bound in a `let`, NOT taken as a module argument:
# secrets/secrets.nix plain-`import`s this file with pkgs/config/lib = null
# to read `sshKeys` without evaluating NixOS, and Nix's laziness means these
# bindings are never forced on that path.  A module argument would be forced
# eagerly and break `agenix -e`.  See hermes/lib.nix for the full rationale.
let
    inherit (import ../lib.nix { inherit pkgs config lib; }) mcp profiles;
in {
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

        # The top-level profile IS the `default` profile (~/.hermes itself,
        # not under profiles/) -- it is what a plain `hermes chat` or a
        # fresh Desktop chat targets when no profile is selected.  So it
        # doubles as the daily driver AND the orchestrator: "just start
        # talking" always lands somewhere useful, and that same chat can
        # route work to the specialists below.
        mcpServers = {
            inherit (mcp) github nixos firecrawl context7 deepwiki;
        };

        soul = ''
            You are Karl's personal assistant running on his homelab. Be concise but thorough.  
            ALWAYS use MCPs if they seem relevant, prefer MCPs over own scripts or knowledge.
            You have access to the internet via web search, a paper search mcp and firecrawl. When asked to perform research, use firecrawl and the paper search mcp for real results.
            You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.

            You also orchestrate Karl's other profiles (see `hermes profile
            list`) through the Kanban board: for work that crosses roles,
            needs to survive a restart, or wants a specialist's narrower
            toolset, create a card and assign it rather than doing
            everything in this session.
        '';

        settings = {
            # Top-level `toolsets`, which is the key the kanban
            # tool-availability gate actually reads -- NOT
            # `platform_toolsets` (what `hermes tools enable` writes, and
            # which that gate ignores).  See hermes-agent issue #83042.
            toolsets = [ "hermes-cli" "kanban" ];

            # Route assignee-less kanban_create calls to the dedicated
            # orchestrator profile instead of falling back to whichever
            # profile happens to be chatting.
            kanban.orchestrator_profile = "orchestrator";
        };

        # Declarative roster, grafted from ../profiles/.  All of these share
        # karl's ONE gateway, HERMES_HOME and ~/.hermes/kanban.db, which is
        # what lets the orchestrator route cards to them.  It does not span
        # Unix accounts: joni/nana/sabine have their own boards.
        #
        # To tweak one preset for karl only, merge over it here, e.g.:
        #   researcher = profiles.researcher // { model = "Qwen3.8-27B"; };
        profiles = {
            inherit (profiles) orchestrator nixos hr researcher;
        };
    };
}
