# secrets/secrets.nix -- agenix recipient rules.
#
# This file is NOT imported into the NixOS configuration.  It exists purely so
# the `agenix` CLI knows which public keys each .age file must be encrypted to.
# Editing a secret (`agenix -e <file>.age`) re-encrypts it to exactly the keys
# listed here, so adding a person to a secret = adding their key below and
# running `agenix -r` (rekey).
#
# Two classes of recipient:
#
#   * users    -- a person's own SSH key (the private half lives on their
#                 laptop; agenix never sees it).  A user must be a recipient
#                 of a secret to CREATE or EDIT it.
#   * systems  -- the machine's SSH *host* key.  The host must be a recipient
#                 of every secret it has to DECRYPT at activation time, since
#                 that is the identity `age.identityPaths` points at.
#
# Rule of thumb: every secret gets [its owner(s)] ++ [the host that uses it].
# Karl is on everything because he administers the box and must be able to
# rekey/recover; that is a deliberate trust decision, not an accident.

let
  # --- user keys (same keys already trusted in hermes_profiles.nix) --------
  karl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface";
  joni = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop";

  users = [ karl joni ];

  # --- machine key --------------------------------------------------------
  # /etc/ssh/ssh_host_ed25519_key.pub on the homeserver.  This is what the
  # machine decrypts with during activation; without it in a secret's
  # publicKeys list, the rebuild cannot open that secret.
  homeserver = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqEd/Iew4ztsH+j5G1gsL9332sccR/5Aiq8Wl3AUpt9 root@nixos";

  systems = [ homeserver ];
in
{
  # --- per-agent Hermes env files ----------------------------------------
  # Replaces the hand-managed /etc/hermes/<agent>.env.  Each is encrypted to
  # its owner + the host, so Joni can edit his own without Karl's key and
  # without ever seeing Karl's.
  "hermes-karl.age".publicKeys = [ karl homeserver ];
  "hermes-joni.age".publicKeys = [ joni karl homeserver ];

  # --- machine-level secrets ---------------------------------------------
  # Not owned by any agent: consumed by a system service. Karl (admin) can
  # edit; the host decrypts at activation.
  # Create with: agenix -e secrets/tailscale-authkey.age
  "tailscale-authkey.age".publicKeys = [ karl homeserver ];
}
