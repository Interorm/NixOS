{
    pkgs, 
    ...
}: {
    networking = {
        networkmanager.enable = true;

        firewall = {
            enable = true;
            allowPing = true;
            
            allowedTCPPorts = [ 22 ];
            # allowedUDPPorts = [ ... ];
        };
    };


    environment.systemPackages = with pkgs; [
        iputils
        openssh tmux
    ];

    services.openssh.enable = true;
}
