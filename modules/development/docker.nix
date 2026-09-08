{
    pkgs,
    ...
}: {
	nixpkgs.config.allowUnfree = true;

	environment.systemPackages = with pkgs; [ docker ];

	virtualisation.docker.enable = true;
	networking.firewall.trustedInterfaces = ["docker0"];
}