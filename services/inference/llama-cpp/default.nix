{
    pkgs, config, lib,
    ...
}: {
    _module.args.cudaPackages = lib.mkOptionDefault pkgs.cudaPackages;

    imports = [ 
        ./llama_cpp.nix 
        ../huggingface-models.nix 
    ];
}