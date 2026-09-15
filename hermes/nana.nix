{
    pkgs,
    ...
}: {
    # Nana's Hermes agent account.  See ./fleet.nix for host-wide settings.
    # No sshKeys of her own yet -- see secrets/secrets.nix's noKeyEditor map,
    # which stands Karl's key in as the editor of her secret in the meantime.
    services.hermes-agents.agents.nana = {
        dashboard.port = 9060;
        mobile.enable = true;

        sshKeys = [];

        soul = ''
            You are Nana's personal assistant focussing on helping her in her studies. Your primary objective is to assist her in her studies and her general daily tasks. 
            Focus on asking clarifying questions when working with her to understand your task and be as helpful as possible.
            When helping her with her studies, make sure to ALWAYS correctly cite any information retrieved from any sources you used when making the reponse. Use harvard citation style.
        '';
    };
}
