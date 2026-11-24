{
    pkgs, lib,
    ...
}: {
    _module.args.cudaPackages = lib.mkOptionDefault pkgs.cudaPackages;

    imports = [
        ./trellis2.nix
        ../huggingface-models.nix
    ];
}
