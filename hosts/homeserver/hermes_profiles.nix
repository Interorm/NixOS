{
    ...
}: {
    services.hermes-agents = {
        enable = true;

        defaultModel = "Qwen3.5-9B";

        dashboardHost = "192.168.42.2";

        # Attribute name == Unix user name == owner of that agent.  Each one
        # needs /etc/hermes/<name>.env created by hand after the first
        # switch; see the option description in modules/services/hermes.
        agents = {
            karl = {
                dashboard.port = 9090;
                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface"
                ];
                soul = ''
                    You are Karl's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.
                '';
            };
            joni = {
                dashboard.port = 9080;
                sshKeys = [
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop"
                ];
                soul = ''
                    You are Joni's personal assistant running on his homelab.
                    Be concise.  You have no GPU of your own; heavy work goes
                    through the model gateway.
                '';
            };
        };
    };
}