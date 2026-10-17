{
    config, lib, ...
}: {
    imports = [ 
            ../../services/hermes

            ./fleet.nix 
            (lib.map (f: ./users + "/${f}") (lib.attrNames (builtins.readDir ./users)))        
    ];
}
