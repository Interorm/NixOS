let
  # Module arguments are never forced for the attributes we read.
  profile = import ../hosts/homeserver/hermes_profiles.nix {
    pkgs = null;
    config = null;
    lib = null;
  };

  agents = profile.services.hermes-agents.agents;

  # The homeserver's SSH *host* key: /etc/ssh/ssh_host_ed25519_key.pub.
  # The host must be a recipient of every secret it decrypts at activation,
  # since that is the identity age.identityPaths points at.  It is a machine
  # fact, not an agent fact, so it lives here.
  homeserver = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqEd/Iew4ztsH+j5G1gsL9332sccR/5Aiq8Wl3AUpt9 root@nixos";
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface";

  # One rule per agent: that person's own keys, plus the host.  Deliberately
  # NOT the admin -- Karl can read any decrypted file as root anyway, but
  # keeping him off the recipient list means the ciphertext at rest is not his
  # to open, and the separation is visible in the repo.
  agentRules = builtins.mapAttrs (name: agent:
    assert agent.sshKeys != [ ] ||
      throw "secrets.nix: agent '${name}' has no sshKeys, so nobody could edit hermes-${name}.age. Add a key in hermes_profiles.nix.";
    { publicKeys = agent.sshKeys ++ [ homeserver ]; }
  ) agents;

  # Re-key the attrset from "<name>" to "hermes-<name>.age", matching the
  # secret names hermes.nix derives.
  hermesSecrets = builtins.listToAttrs (map (name: {
    name = "hermes-${name}.age";
    value = agentRules.${name};
  }) (builtins.attrNames agentRules));

  # Agents with googleWorkspace.enable additionally get google-<name>.age,
  # holding their OAuth client secret JSON.  Derived from the same profile, so
  # enabling the option in hermes_profiles.nix is the only edit needed -- the
  # rule appears here on its own.
  googleAgents = builtins.filter
    (name: (agents.${name}.googleWorkspace or { }).enable or false)
    (builtins.attrNames agents);

  googleSecrets = builtins.listToAttrs (map (name: {
    name = "google-${name}.age";
    value = agentRules.${name};
  }) googleAgents);

  # --- machine-level secrets ---------------------------------------------
  # Owned by the machine, not a person: consumed by a system service.
  machineSecrets = {
    "tailscale-homeserver.age".publicKeys = [ admin homeserver ];
    # restic repository password for the local SATA backup disk.  Machine
    # secret: consumed by a root systemd unit, belongs to no agent.
    "restic-homeserver.age".publicKeys = [ admin homeserver ];
  };
in
hermesSecrets // googleSecrets // machineSecrets
