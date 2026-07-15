{
    pkgs,
    ...
}: {
	nixpkgs.config.allowUnfree = true;

	environment.systemPackages = with pkgs; [ docker ];

	virtualization.docker.enable = true;
	networking.firewall.trustedInterfaces = ["docker0"];
}