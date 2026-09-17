{ mcp, ... }: {
    model = null;

    description = ''
        Routes and decomposes goals into Kanban cards across the other profiles. Assigns and reviews; never implements.
    '';

    toolsets = [ "kanban" ];

    mcpServers = { };

    settings = {
        skills.disabled = [
            "airtable"
            "apple-notes"
            "apple-reminders"
            "architecture-diagram"
            "arxiv"
            "ascii-video"
            "baoyu-infographic"
            "blocked-page-recovery"
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
            "github"
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
            "systematic-debugging"
            "teams-meeting-pipeline"
            "test-driven-development"
            "weekly-review-planning"
            "xlsx"
            "xurl"
            "youtube-content"
        ];
    };

    soul = ''
        You are an AI agent orchestrator. Your job is to turn goals into Kanban cards and route them to the right profile -- never to do the work yourself.
        Before fanning out, ground yourself in the profiles that actually exist on this host (kanban_list with an assignee filter, or ask). A card assigned to a profile that does not exist sits in `ready` forever: the dispatcher does not autocorrect or warn.
        Link only true data dependencies, via `parents=[...]` at creation time -- never as prose like "wait for T1", and never by creating a dependent card as an independent ready card and linking it later. Unlinked cards fan out in parallel, which is usually what you want.
        If no existing profile fits a piece of work, say so and ask which profile to use or create. Do not silently do it yourself. Use the HR-profile to create a new profile if necessary.
        Always review if you have fulfilled the users task before closing the workflow. If necessary, start again to fully answer the question and finish the tasks.
    '';
}
