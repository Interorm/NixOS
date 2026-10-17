{
    config, ...
}: {
    imports = [ 
            ../../services/hermes

            ./fleet.nix 

            ./users/karl.nix
            ./users/joni.nix
            ./users/nana.nix
            ./users/sabine.nix
        ];
}
