{
  pkgs, config, lib,
  ...
}: {
  	nixpkgs.config.allowUnfree = true;
  	nixpkgs.config.cudaSupport = true;

  	environment.systemPackages = with pkgs; [
        cudaPackages.cudatoolkit
        cudaPackages.cudnn
        cudaPackages.cuda_nvcc
    ];

    environment.variables = {
        CUDA_PATH = "${pkgs.cudaPackages.cudatoolkit}";
        CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
    };

    nix.settings = {
        substituters = [ "https://cache.nixos-cuda.org" ];
        trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
    };
}