{ pkgs, config, lib, ... }:

let
    inherit (import ../lib.nix { inherit pkgs config lib; }) mcp;
in {
    # Nana's Hermes agent account -- study support.  No sshKeys of her own
    # yet, so secrets/secrets.nix's noKeyEditor map stands Karl's key in as
    # the editor of her secret until she has a keypair.
    services.hermes-agents.agents.nana = {
        dashboard.port = 9060;
        mobile.enable = true;

        sshKeys = [];

        # Research-shaped loadout: she needs sources and citations, not
        # GitHub or Nix.
        mcpServers = {
            inherit (mcp) firecrawl context7;
        };

        soul = ''
            You are Nana's personal assistant focussing on helping her in her studies. Your primary objective is to assist her in her studies and her general daily tasks. 
            Focus on asking clarifying questions when working with her to understand your task and be as helpful as possible.
            When helping her with her studies, make sure to ALWAYS correctly cite any information retrieved from any sources you used when making the reponse. Use harvard citation style.
        '';

        profiles = { };
    };
}
