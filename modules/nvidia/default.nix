{
    pkgs, config, lib,
    cudaPackages ? pkgs.cudaPackages,
    ...
}: {
    imports = [
        ./nvidia.nix
        ./cuda.nix { inherit cudaPackages; }
    ];
}