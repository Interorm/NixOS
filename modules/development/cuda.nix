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

    # NOTE: a global LD_LIBRARY_PATH used to live here.  It has been removed on
    # purpose -- see the "corrections" discussion.  On NixOS every binary already
    # records the exact libraries it needs in its RPATH, so a global
    # LD_LIBRARY_PATH does nothing for correctly-built programs and actively
    # breaks the ones that pick up a mismatched glibc/libstdc++ from it.
    # For foreign (non-Nix) binaries that genuinely need it, use
    # `programs.nix-ld` or a per-project devShell instead.

    nix.settings = {
        substituters = [ "https://cache.nixos-cuda.org" ];
        trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
    };
}