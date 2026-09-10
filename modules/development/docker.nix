{
    pkgs,
    ...
}: {
	nixpkgs.config.allowUnfree = true;

	environment.systemPackages = with pkgs; [ docker ];

	virtualisation.docker.enable = true;
	virtualisation.oci-containers.backend = "docker";
	hardware.nvidia-container-toolkit.enable = true;
	
	networking.firewall.trustedInterfaces = ["docker0"];
}