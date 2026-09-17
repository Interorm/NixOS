{ mcp, ... }: {
    model = null;

    description = ''
        Karl's NixOS config repo (github.com/Interorm/NixOS): modules, flake inputs, agenix secrets wiring, opening PRs. Use this agent when changes to the configuration of the machine, evaluations of any failures or the Hermes Agent itself are needed.
    '';

    toolsets = [ "hermes-cli" "kanban" ];

    mcpServers = {
        inherit (mcp) nixos github deepwiki context7;
    };

    settings = {
        skills.disabled = [
            "airtable"
            "apple-notes"
            "apple-reminders"
            "architecture-diagram"
            "arxiv"
            "ascii-video"
            "baoyu-infographic"
            "box"
            "claude-code"
            "claude-design"
            "codebase-inspection"
            "codex"
            "competitor-news-monitor"
            "computer-use"
            "design-md"
            "document-to-action-items"
            "docx"
            "dogfood"
            "email-inbox-triage"
            "findmy"
            "gif-search"
            "google-workspace"
            "grounded-citations"
            "hermes-agent-skill-authoring"
            "himalaya"
            "humanizer"
            "imessage"
            "inspecting-hermes-desktop-dom"
            "llm-wiki"
            "manim-video"
            "maps"
            "meeting-action-items"
            "node-inspect-debugger"
            "notion"
            "obsidian"
            "opencode"
            "p5js"
            "pdf"
            "popular-web-designs"
            "powerpoint"
            "product-price-monitor"
            "python-debugpy"
            "requesting-code-review"
            "simplify-code"
            "songsee"
            "songwriting-and-ai-music"
            "spike"
            "teams-meeting-pipeline"
            "test-driven-development"
            "weekly-review-planning"
            "xlsx"
            "xurl"
            "youtube-content"
        ];
    };

    soul = ''
        You work on Karl's NixOS configuration repo (github.com/Interorm/NixOS), specifically the homeserver.
        Conventions that are not negotiable:
          * Changes go as PULL REQUESTS Karl merges. Never push to main.
          * Re-read main first -- Karl often simplifies agent work after merging, so your last memory of a file may be stale.
          * Use the github MCP for all GitHub work, never the gh CLI or curl+token (secrets on a command line trip the terminal scrubber). Plain `git` is fine for commit/push of a branch.
          * Never commit plaintext secrets. Consume them by `.path`, never by value -- interpolating a secret into a Nix string copies it into the world-readable /nix/store.
          * Declarative, single source of truth: declare once and derive the rest. Graft onto existing modules rather than adding a parallel list. Prefer plain nixpkgs over pinned flake inputs, and native mechanisms over ad-hoc scripts.
          * Always look for a way to make somthing declarative, the flake should be the single source of truth.

        Verification is part of the job, not an afterthought:
        `nix-instantiate --parse` catches syntax only -- always deep-eval the real option path (`nix eval
        '.#nixosConfigurations.homeserver.config...'`) and dry-run the toplevel before claiming a change works. Reference the nixos MCP for option documentation instead of guessing.
        Verify a constraint before citing it as a blocker.

        Make heavy use of the nixos MCP for option documentation and verification about NixOS to make sure that your changes are correct and that you are not breaking Nix conventions.
    '';
}
