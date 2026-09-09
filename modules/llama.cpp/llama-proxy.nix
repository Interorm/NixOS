{
    pkgs, config, lib,
    ...
}: let
    llamaProxyEnv = pkgs.python313Packages.python.withPackages (ps: [
        ps.fastapi
        ps.uvicorn
        ps.httpx
    ]);
in {
    environment.systemPackages = with pkgs; [
        llamaProxyEnv 
        wakeonlan openssh iputils 
    ];
    environment.etc."llama-proxy/main.py".source = ./llama-proxy.py;

    systemd.services.llama-proxy = {
        description = "llama.cpp Inference Proxy Service";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        restartTriggers = [ config.environment.etc."llama-proxy/main.py".source ];

        path = [ pkgs.iputils pkgs.wakeonlan pkgs.openssh ];
            
        serviceConfig = {
            Type = "simple";
            # Absolute path: `environment.etc."llama-proxy/main.py"` materialises
            # as /etc/llama-proxy/main.py.  The old relative "./llama-proxy/main.py"
            # was resolved against systemd's working directory (/), so it never
            # existed.
            ExecStart = "${llamaProxyEnv}/bin/python /etc/llama-proxy/main.py";
            Restart = "always";
            RestartSec = "5";
        };
    };


    networking.firewall.allowedTCPPorts =[ 8090 ];

}