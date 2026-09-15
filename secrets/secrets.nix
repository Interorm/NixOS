let
  # Module arguments are never forced for the attributes we read.
  #
  # One import per account file under hermes/users/ (not the merged
  # hermes/default.nix, which is a NixOS module fragment -- an `imports`
  # list, not something plain `import` merges).  Each returns a plain
  # attrset shaped `{ services.hermes-agents.agents.<name> = {...}; }`, so
  # `//` across all of them gives the `agents` set this file needs.
  #
  # The dummy nulls work because Nix is lazy and this file only ever reads
  # `sshKeys` / `googleWorkspace.enable`.  The user files bind the MCP and
  # profile registries (hermes/lib.nix) in a `let`, which is never forced on
  # this path -- that is exactly why lib.nix is `let`-bound there rather than
  # taken as a module argument, which would force it and break `agenix -e`.
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

  # The homeserver's SSH *host* key: /etc/ssh/ssh_host_ed25519_key.pub.
  # The host must be a recipient of every secret it decrypts at activation,
  # since that is the identity age.identityPaths points at.  It is a machine
  # fact, not an agent fact, so it lives here.
  homeserver = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqEd/Iew4ztsH+j5G1gsL9332sccR/5Aiq8Wl3AUpt9 root@nixos";
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface";

  # Agents with no SSH key of their own yet (e.g. a family member who hasn't
  # generated a keypair): whose key stands in as the editor of their secret,
  # until they get one and are added to sshKeys in hermes/users/<name>.nix -- at
  # which point remove them from this map and the normal per-agent rule
  # below takes over on its own.
  noKeyEditor = {
    sabine = admin;
    nana = admin;
  };

  # One rule per agent: that person's own keys, plus the host.  Deliberately
  # NOT the admin -- Karl can read any decrypted file as root anyway, but
  # keeping him off the recipient list means the ciphertext at rest is not his
  # to open, and the separation is visible in the repo.
  agentRules = builtins.mapAttrs (name: agent:
    if agent.sshKeys != [ ] then
      { publicKeys = agent.sshKeys ++ [ homeserver ]; }
    else if noKeyEditor ? ${name} then
      { publicKeys = [ noKeyEditor.${name} homeserver ]; }
    else
      throw "secrets.nix: agent '${name}' has no sshKeys, so nobody could edit hermes-${name}.age. Add a key in hermes/users/${name}.nix, or an entry in noKeyEditor here."
  ) agents;

  # Re-key the attrset from "<name>" to "hermes-<name>.age", matching the
  # secret names hermes.nix derives.
  hermesSecrets = builtins.listToAttrs (map (name: {
    name = "hermes-${name}.age";
    value = agentRules.${name};
  }) (builtins.attrNames agentRules));

  # Agents with googleWorkspace.enable additionally get google-<name>.age,
  # holding their OAuth client secret JSON.  Derived from the same profile, so
  # enabling the option in hermes/users/<name>.nix is the only edit needed -- the
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
    "restic-homeserver.age".publicKeys = [ admin homeserver ];
  };
in
hermesSecrets // googleSecrets // machineSecrets
