{
    config, ...
}: {
    imports = [ 
            ./
            ./fleet.nix 
        ]
        ++ builtins.map (user: ./users/${user}.nix) (builtins.attrNames config.services.hermes-agents.agents);
}
