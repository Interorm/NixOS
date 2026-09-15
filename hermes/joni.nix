{
    pkgs,
    ...
}: {
    # Joni's Hermes agent account.  See ./fleet.nix for host-wide settings.
    services.hermes-agents.agents.joni = {
        dashboard.port = 9080;
        mobile.enable = true;

        sshKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop"
        ];
        extraPackages = with pkgs; [ elan ];

        soul = ''
            You are Karl's personal assistant running on his homelab. Be concise but thorough.  
            ALWAYS use MCPs if they seem relevant, prefer MCPs over own scripts or knowledge.
            You have access to the internet via web search, a paper search mcp and firecrawl. When asked to perform research, use firecrawl and the paper search mcp for real results.
            You have access to a nix environment, so you can run nix commands. Reference the NixOS mcp for documentation whenever there is a Nix-adjacent task.

        '';
    };
}
