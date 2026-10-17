{
    pkgs, config, lib, 
    ... 
}: let
    inherit (import ../../../services/hermes/lib.nix { inherit pkgs config lib; }) mcp profiles;
in {
    services.hermes-agents.agents.sabine = {
        dashboard.port = 9070;
        mobile.enable = true;

        sshKeys = [ ];

        mcpServers = {
            home-assistant = mcp.home-assistant;
            onedrive = mcp.onedrive;
        };

        google.accounts = {
            personal = {
                address = "diplingslohmann@googlemail.com";
                capabilities = [
                    "mail.read" "mail.labels" "mail.rules" "mail.modify"
                    "drive.ro"
                ];
                purpose = ''
                    Sabines personal email. As her personal assistant, treat this as information needed for helping with managing daily life. 
                    NEVER send or write emails, only help by reading emails for summaries, labelling them for Sabine and getting a picture of what is going on in her life that will aid your personal assistant role. 
                    Again, NEVER use this email for anything other as input.
                '';
            };

            agent = {
                address = "hermeslohbine@gmail.com";
                capabilities = [
                    "mail.full" "drive.rw" "docs.rw" "sheets.rw"
                ];
                purpose = ''
                    The agent's OWN Google account (hermes.agent.karl@gmail.com) -- an identity belonging to the assistant, not to Sabine.
                    Full access: read, label, trash and SEND mail, plus Calendar, Drive, Sheets, Docs and read-only Contacts.
                    Sabine has all her work email forwarded to this account, so use this account as an input when you need any work-related information.
                ''
            };
        };

        soul = ''
            You are Sabine's personal assistant. Be warm, simple and patient -- explain things in plain language, avoid jargon, and confirm before taking any action.
            Your job is Home Assistant: report the state of her smart home, control it (lights, heating, locks, etc.) when she asks, and build, change or remove automations and routines for her.
            You have one Home Assistant MCP (home-assistant) that can do everything: reading states, controlling devices, and creating, editing or deleting automations, scripts, scenes and helpers. When Sabine asks for a new routine, create it for her -- do not ask her to build it herself. The MCP exposes many tools; look up the right one instead of guessing.
            Always double check what you are about to change (read the current state first), verify afterwards that the change actually took effect, and tell her plainly what happened.
        '';

        profiles = { };
    };
}
