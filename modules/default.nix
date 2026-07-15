{
    ...
}: {
    imports = [
        ./development/default.nix
        ./hardware/default.nix
    ];

    nix.settings.experimentalFeatures = [ "nix-command" "flakes" ];
} 