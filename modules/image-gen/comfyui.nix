{
    inputs, lib, config,
    ...
}: {
    imports = [ 
        inputs.comfyui-nix.nixosModules.default 
    ];

    services.comfyui = {
        enable = true;

        gpuSupport = "cuda";
        enableManager = true;

        port = 8180;
        listenAddress = "0.0.0.0";
        openFirewall = true;

        dataDir = "/var/lib/comfyui";
    };
}
