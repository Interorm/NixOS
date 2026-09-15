# Orchestrator -- routes and decomposes, does not do the work itself.
#
# Deliberately has NO terminal/file/web tools: `toolsets = [ "kanban" ]` is
# the whole surface.  That is the point -- an orchestrator that can edit
# files will start editing files instead of delegating, and the upstream
# kanban-orchestrator skill's "don't do the work yourself" rule is advice
# the model can skip, whereas an absent tool cannot be called.
#
# `toolsets` here is the TOP-LEVEL config.yaml key, which is the one the
# kanban tool-availability gate reads (tools/kanban_tools.py ::
# _profile_has_kanban_toolset) -- NOT `platform_toolsets`, which is what
# `hermes tools enable kanban` writes and which that gate ignores.  See
# hermes-agent issue #83042.
{ mcp, ... }: {
    # null inherits the parent agent's model.  An orchestrator only writes
    # short routing decisions, so the agent default is usually right; pin a
    # stronger model here if decomposition quality matters more than cost.
    model = null;

    description = ''
        Routes and decomposes goals into Kanban cards across the other
        profiles. Assigns and reviews; never implements.
    '';

    toolsets = [ "kanban" ];

    # No MCP servers on purpose: every MCP loads its tool schemas into the
    # prefill of every request this profile makes, and a router needs none
    # of them.
    mcpServers = { };

    settings = { };

    soul = ''
        You are the orchestrator. Your job is to turn goals into Kanban
        cards and route them to the right profile -- never to do the work
        yourself.

        Before fanning out, ground yourself in the profiles that actually
        exist on this host (kanban_list with an assignee filter, or ask).
        A card assigned to a profile that does not exist sits in `ready`
        forever: the dispatcher does not autocorrect or warn.

        Link only true data dependencies, via `parents=[...]` at creation
        time -- never as prose like "wait for T1", and never by creating a
        dependent card as an independent ready card and linking it later.
        Unlinked cards fan out in parallel, which is usually what you want.

        If no existing profile fits a piece of work, say so and ask which
        profile to use or create. Do not silently do it yourself.
    '';
}
