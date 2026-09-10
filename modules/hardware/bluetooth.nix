{
    pkgs,
    ...
}: {
   hardware.bluetooth = {
      enable = true;
      powerOnBoot = false;
   };


   environment.systemPackages = with pkgs; [
      bluetoothctl
      blueman
   ];
}