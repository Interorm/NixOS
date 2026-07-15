{
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
        openshh tmux
    ];

    services.openssh.enable = true;
}
