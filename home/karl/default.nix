{ 
    config, pkgs, inputs, ... 
}: {
    home.username = "karl";
    home.homeDirectory = "/home/karl";
    home.stateVersion = "26.05"; 

    imports = [ ./git.nix ./desktop.nix ];
}