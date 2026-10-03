{
    pkgs,
    ...
}: {
   hardware.bluetooth = {
      enable = true;
      powerOnBoot = false;
   };


   environment.systemPackages = with pkgs; [
      blueman
   ];

   services.blueman.enable = true;
}