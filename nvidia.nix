{
    config,
    pkgs,
    lib,
    ...
}: {
    nixpkgs.config.allowUnfree = true;

    hardware.graphics = {
        enable = true;
        enable32Bit = true;
    };

    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        open = true;

        modesetting.enable = true;
        nvidiaSettings = true;

        powerManagement.enable = false;
    };


    environment.systemPackages = with pkgs; [
        cudaPackages.cudatoolkit
        cudaPackages.cudnn
        cudaPackages.cuda_nvcc
    ];

    environment.variables = {
        CUDA_PATH = "${pkgs.cudaPackages.cudatoolkit}";
        CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
    };

    environment.sessionVariables = {
        LD_LIBRARY_PATH = lib.mkForce (lib.concatStringsSep ":" [
            "${pkgs.cudaPackages.cudatoolkit}/lib"
            "${pkgs.cudaPackages.cudnn}/lib"
            "${pkgs.stdenv.cc.cc.lib}/lib"
            "${pkgs.zlib}/lib"
            "/run/opengl-driver/lib"
            "/run/opengl-driver-32/lib"
        ]);
    };

    nix.settings = {
        substituters = [ "https://cache.nixos-cuda.org" ];
        trusted-public-keys = [ "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=" ];
    };
}
