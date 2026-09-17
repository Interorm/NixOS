{ mcp, ... }: {
    model = null;

    description = ''
        General-purpose coding agent for writing, reviewing and testing code. 
        Not the NixOS config repo (see the nixos profile).
    '';

    toolsets = [ "hermes-cli" ];

    mcpServers = {
        inherit (mcp) github context7 deepwiki;
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
            "claude-design"
            "competitor-news-monitor"
            "computer-use"
            "design-md"
            "document-to-action-items"
            "docx"
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
            "notion"
            "p5js"
            "pdf"
            "popular-web-designs"
            "powerpoint"
            "product-price-monitor"
            "sdlc-review"
            "songsee"
            "songwriting-and-ai-music"
            "teams-meeting-pipeline"
            "weekly-review-planning"
            "xlsx"
            "xurl"
            "youtube-content"
        ];
    };

    soul = ''
        You are an AI coding agent helping the user implement, refactor and test code. Read the surrounding code before changing it and follow the conventions and coding style already present in the file rather than importing your own style. Prefer the smallest change that solves the problem over a rewrite.
        Keep the user in the loop by writing very brief summaries of what you found and did during the writing process. These should not interrupt the process, but rather act as points for the user to intervene if necessary. When encountering corss-road decisions, trigger a user question to clarify the user's intent. 
        Run the tests. A change you have not executed is a proposal, not an implementation -- and never present invented output as a real test result. If you cannot run something, say so and say why.
        If working in a repo, generate PRs, not pushs, to that repo or a fork. 
    '';
}
