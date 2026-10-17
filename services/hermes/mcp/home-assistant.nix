{ ... }: {
    url = "\${HA_URL_FULLACCESS}";
    meta = {
        description = "Full mcp-based access to home assistant.";
        requires.envVars = [ "HA_URL_FULLACCESS" ];
    };
}
