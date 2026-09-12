# Secrets (agenix)

Secrets live in this repo as **age-encrypted** `.age` files. They are safe to
commit and safe to publish: only the private SSH keys listed in
`secrets/secrets.nix` can decrypt them. The homeserver decrypts them at
activation using its **SSH host key**, into `/run/agenix/<name>` (a tmpfs, so
plaintext never lands on disk).

This replaces the hand-made `/etc/hermes/<agent>.env` files. The win: secrets
survive a rebuild-from-scratch, each person manages their own without seeing
anyone else's, and adding one is a reviewable PR instead of an SSH session.

## Who can decrypt what

Defined in `secrets/secrets.nix` (that file is *not* part of the NixOS config —
it only tells the `agenix` CLI which keys to encrypt to).

| Secret | Recipients | Purpose |
|---|---|---|
| `hermes-karl.age` | karl, homeserver | Karl's agent env (API keys, tokens) |
| `hermes-joni.age` | joni, karl, homeserver | Joni's agent env |
| `tailscale-authkey.age` | karl, homeserver | machine-level: Tailscale auth key |

Every secret is encrypted to **its owner + the homeserver**. The host must be a
recipient or it cannot decrypt at boot. Karl is on all of them as the box
administrator (needed to rekey and recover) — a deliberate trust decision.

## Adding or editing your own secret

Requires the private key matching your entry in `secrets/secrets.nix`
(`~/.ssh/id_ed25519` on your laptop). You never send it anywhere.

```bash
git clone git@github.com:Interorm/NixOS.git && cd NixOS

# Opens $EDITOR on the decrypted content; re-encrypts on save.
agenix -e secrets/hermes-joni.age

# The file is KEY=value, exactly like the old .env:
#   OPENAI_API_KEY=...
#   TELEGRAM_BOT_TOKEN=...

git add secrets/hermes-joni.age
git commit -m "Update joni's agent secrets"
git push   # open a PR; the diff is ciphertext, so review leaks nothing
```

`agenix` is on the homeserver's PATH, so you can also do this over SSH on the
box itself.

## Adding a NEW secret

1. Add a rule to `secrets/secrets.nix`:
   ```nix
   "my-new-secret.age".publicKeys = [ karl homeserver ];
   ```
2. Create it: `agenix -e secrets/my-new-secret.age`
3. Declare it in a module so the host decrypts it:
   ```nix
   age.secrets.my-new-secret = {
     file = ../../secrets/my-new-secret.age;
     owner = "root";
     mode = "0400";
   };
   ```
4. Consume it by **path**, never by value:
   ```nix
   services.foo.environmentFile = config.age.secrets.my-new-secret.path;
   ```

## Machine-level secrets (e.g. Tailscale)

Same flow, owned by `root` and consumed by a system service. For Tailscale:

```nix
services.tailscale = {
  enable = true;
  authKeyFile = config.age.secrets.tailscale-authkey.path;
};

age.secrets.tailscale-authkey = {
  file = ../../secrets/tailscale-authkey.age;
  owner = "root";
  mode = "0400";
};
```

## Migrating off /etc/hermes/<agent>.env

The agents currently read `/etc/hermes/<name>.env`. To switch one over:

```bash
# 1. copy the existing plaintext into the encrypted file
agenix -e secrets/hermes-karl.age      # paste the contents of /etc/hermes/karl.env

# 2. point the agent at the decrypted path (hermes_profiles.nix)
#    services.hermes-agents.agents.karl.environmentFile =
#        config.age.secrets."hermes-karl".path;

# 3. rebuild, confirm the agent still starts, THEN remove the old file
sudo rm /etc/hermes/karl.env
```

Do one agent at a time and verify the gateway comes up before deleting
anything — a missing env file is a silent auth failure, not a loud one.

## Rotating / recovering

- **Add a person to an existing secret**: add their key in `secrets/secrets.nix`,
  then `agenix -r` (rekey all) — needs a private key that can already decrypt.
- **Host key regenerated** (reinstall, new disk): every secret must be rekeyed
  with the new host key, or activation fails to decrypt. Keep a user key as a
  recipient on everything so recovery is always possible.
- **Lost all private keys for a secret**: it is unrecoverable by design.
  Rotate the underlying credential upstream and create a fresh secret.

## Threat model

- `.age` files are safe in a public repo, but this is still *harvest now,
  decrypt later* exposure. Prefer credentials you can rotate.
- agenix has not had a formal security audit (upstream says so plainly).
- `/run/agenix` is tmpfs — plaintext is gone on reboot, never on disk.
