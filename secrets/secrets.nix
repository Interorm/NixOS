# secrets/secrets.nix -- agenix recipient rules.
#
# NOT imported into the NixOS configuration.  It exists purely so the `agenix`
# CLI knows which public keys each .age file must be encrypted to.  Editing a
# secret (`agenix -e <file>.age`) re-encrypts it to exactly the keys listed
# here, so changing who can read a secret = editing this file and running
# `agenix -r`.
#
# Two classes of recipient:
#
#   * users    -- a person's own SSH key.  The private half never leaves their
#                 laptop.  A user must be a recipient to CREATE or EDIT a
#                 secret.
#   * systems  -- the machine's SSH *host* key.  The host must be a recipient
#                 of every secret it decrypts at activation, since that is the
#                 identity `age.identityPaths` points at.
#
# Rule: every secret gets [whoever must edit it] ++ [the host that uses it].

let
  # --- user keys (the same keys trusted in hermes_profiles.nix) ------------
  karl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMH2S3ZA0agXgsNM8RWJ1JvJrfe2Bq00Zc2mQwmjhAjX karli@Karls-Surface";
  joni = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOH8RZAPIW6QtCf47hpdpLhPVd30PtbktPPSQJ6JooPd jonbrod@laptop";

  # --- machine key --------------------------------------------------------
  # /etc/ssh/ssh_host_ed25519_key.pub on the homeserver.
  homeserver = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqEd/Iew4ztsH+j5G1gsL9332sccR/5Aiq8Wl3AUpt9 root@nixos";
in
{
  # --- per-agent Hermes env files ----------------------------------------
  # Each agent's secret is encrypted to THAT PERSON plus the host, and nobody
  # else.  Karl is deliberately NOT a recipient of Joni's secret: as box
  # administrator he could always read the decrypted file as root, but keeping
  # him off the recipient list means the *stored ciphertext* is not his to
  # open, the separation is visible in the repo, and an accidental `agenix -d`
  # cannot casually reveal it.
  #
  # Consequence to be aware of: if Joni loses his laptop key, his secret is
  # unrecoverable -- it must be recreated and the upstream credentials rotated.
  # That is the price of the separation, and it is the right trade for secrets
  # that are all individually rotatable API tokens.
  "hermes-karl.age".publicKeys = [ karl homeserver ];
  "hermes-joni.age".publicKeys = [ joni homeserver ];

  # --- machine-level secrets ---------------------------------------------
  # Owned by the machine, not a person: consumed by a system service. Karl
  # administers the box, so he is the editor here.
  "tailscale-authkey.age".publicKeys = [ karl homeserver ];
}
