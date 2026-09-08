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

    imports = [ ../../development/cuda.nix ];

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
            ExecStart = "${llamaProxyEnv}/bin/python ./llama-proxy/main.py";
            Restart = "always";
            RestartSec = "5";
        };
    };


    networking.firewall.allowedTCPPorts =[ 8090 ];

}