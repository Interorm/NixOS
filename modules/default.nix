{
    ...
}: {
    imports = [
        ./development/default.nix
        ./hardware/default.nix
    ];

    nix.settings.experimental-features = [ "nix-command" "flakes" ];
} 