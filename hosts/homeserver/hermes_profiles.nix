{
    ...
}: {
    services.hermes-agents = {
        enable = true;

        defaultModel = "Qwen3.5-9B";

        # Attribute name == Unix user name == owner of that agent.  Each one
        # needs /etc/hermes/<name>.env created by hand before the first
        # switch; see the option description in modules/services/hermes.
        agents = {
            karl = {
                soul = ''
                    You are Karl's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.
                '';
            };
            joni = {
                soul = ''
                    You are Joni's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.
                '';
            };
        };
    };
}