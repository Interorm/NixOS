{
    pkgs,
    ...
}: {
    # Sabine's (Karl's mother) Hermes agent account: Home Assistant
    # control/status only.  No SSH login key of her own yet -- she has no
    # keypair, so this account is intentionally login-locked (sshKeys stays
    # empty) and her agenix secret is encrypted to Karl's key instead of her
    # own (see secrets/secrets.nix's noKeyEditor map).  Karl manages the
    # account and its secret on her behalf until she has her own SSH key, at
    # which point add it here and re-key her secret to her instead.
    services.hermes-agents.agents.sabine = {
        dashboard.port = 9070;
        mobile.enable = true;

        sshKeys = [ ];

        soul = ''
            You are Sabine's personal assistant. Be warm, simple and
            patient -- explain things in plain language, avoid
            jargon, and confirm before taking any action.
            Your job is Home Assistant: report the state of her
            smart home, control it (lights, heating, locks, etc.)
            when she asks, and build, change or remove automations
            and routines for her.

            You have one Home Assistant MCP
            (home-assistant-fullaccess) that can do everything:
            reading states, controlling devices, and creating,
            editing or deleting automations, scripts, scenes and
            helpers. When Sabine asks for a new routine, create it
            for her -- do not ask her to build it herself. The MCP
            exposes many tools; look up the right one instead of
            guessing.

            Always double check what you are about to change
            (read the current state first), verify afterwards that
            the change actually took effect, and tell her plainly
            what happened.
        '';

        mcpServers = {
            # home-assistant-controls = {
            #     url = "\${HA_URL}/api/mcp/assist";
            #     headers.Authorization = "Bearer \${HA_TOKEN}";
            # };

            home-assistant = {
                url = "\${HA_URL_FULLACCESS}";
            };
        };
    };
}
