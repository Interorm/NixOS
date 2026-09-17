{ mcp, ... }: {
    model = "Qwen3.8-27B";

    description = ''
        Web research, document analysis, fact-checking and citation gathering. Produces sourced findings, not code.
    '';

    toolsets = [ "hermes-cli" ];

    mcpServers = {
        inherit (mcp) firecrawl context7 deepwiki;
    };

    settings = {
        skills.disabled = [
            "airtable"
            "apple-notes"
            "apple-reminders"
            "architecture-diagram"
            "ascii-video"
            "baoyu-infographic"
            "box"
            "claude-code"
            "claude-design"
            "codebase-inspection"
            "codex"
            "computer-use"
            "design-md"
            "document-to-action-items"
            "dogfood"
            "email-inbox-triage"
            "findmy"
            "gif-search"
            "github"
            "hermes-agent-skill-authoring"
            "himalaya"
            "imessage"
            "inspecting-hermes-desktop-dom"
            "manim-video"
            "maps"
            "meeting-action-items"
            "node-inspect-debugger"
            "notion"
            "opencode"
            "p5js"
            "popular-web-designs"
            "powerpoint"
            "product-price-monitor"
            "python-debugpy"
            "requesting-code-review"
            "sdlc-review"
            "simplify-code"
            "songsee"
            "songwriting-and-ai-music"
            "spike"
            "systematic-debugging"
            "teams-meeting-pipeline"
            "test-driven-development"
            "weekly-review-planning"
            "xurl"
        ];
    };

    soul = ''
        You are a deep research specialist. Use websearch and especially firecrawl for real crawling and extraction rather than relying on recalled knowledge, and prefer  primary sources over summaries of them. 
        If the topic is academic in nature or could benefit from actual scientific sources, try to find and download papers that could be relevant. Process these with the read_file pdf tool. When dealing with academic sources, use common research-techniques to generate a comprehensive overview of the topic instead of relying on individual sources.
        Every non-obvious claim carries a citation with a resolvable URL. Distinguish clearly between what a source states, what you infer from it, and what you could not verify -- an honest "not found" is more useful than a confident guess.
        When findings will be handed to another profile through Kanban, put the machine-readable facts in kanban_complete's `metadata` (sources_read, recommendation, key numbers) and keep `summary` to a few human sentences.
    '';
}
