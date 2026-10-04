let
  agentFiles = [
    ../hermes/users/karl.nix
    ../hermes/users/joni.nix
    ../hermes/users/nana.nix
    ../hermes/users/sabine.nix
  ];

  dummyArgs = { pkgs = null; config = null; lib = null; };

  agents = builtins.foldl'
    (acc: f: acc // (import f dummyArgs).services.hermes-agents.agents)
    {}
    agentFiles;

  homeserver = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqEd/Iew4ztsH+j5G1gsL9332sccR/5Aiq8Wl3AUpt9 root@nixos";
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface";

  agentRules = builtins.mapAttrs (name: agent:
    if agent.sshKeys != [ ] then
      { publicKeys = agent.sshKeys ++ [ homeserver ]; }
    else
      { publicKeys = [ admin homeserver ]; }
  ) agents;

  # Re-key the attrset from "<name>" to "hermes-<name>.age", matching the
  # secret names hermes.nix derives.
  hermesSecrets = builtins.listToAttrs (map (name: {
    name = "hermes-${name}.age";
    value = agentRules.${name};
  }) (builtins.attrNames agentRules));

  machineSecrets = {
    "tailscale-homeserver.age".publicKeys = [ admin homeserver ];
    "restic-homeserver.age".publicKeys = [ admin homeserver ];
    "google-client.age".publicKeys = [ admin homeserver ];
  };
in
hermesSecrets // machineSecrets
