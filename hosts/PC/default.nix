{...}: {

    imports = [
        ./hardware-configuration.nix
        ../../modules/default.nix

        ./users.nix
    ];

    network.hostname = "Karls-PC";
}