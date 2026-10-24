{
    pkgs, config, lib,
    ...
}: {
    _module.args.cudaPackages = lib.mkOptionDefault pkgs.cudaPackages;

    imports = [
        ./nvidia.nix
        ./cuda.nix
    ];
}