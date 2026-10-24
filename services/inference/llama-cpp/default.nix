{
    pkgs, config, lib,
    cudaPackages ? pkgs.cudaPackages,
    ...
}: {
    imports = [ 
        ./llama_cpp.nix  { inherit cudaPackages; }
        ../huggingface-models.nix 
    ];
}