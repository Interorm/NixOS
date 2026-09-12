# Secrets (agenix)

Secrets live in this repo as **age-encrypted** `.age` files. They are safe to
commit and safe to publish: only the private SSH keys listed in
`secrets/secrets.nix` can decrypt them. The homeserver decrypts them at
activation with its **SSH host key**, into `/run/agenix/<name>` — a tmpfs, so
plaintext never lands on disk.

## How it fits together

There are two kinds of secret, wired in two different places:

| Kind | Declared where | Example |
|---|---|---|
| **Per-agent** | **Automatic** — derived from `services.hermes-agents.agents` in `modules/services/hermes/hermes.nix` | `hermes-karl`, `hermes-joni` |
| **Machine-level** | By hand in `modules/services/secrets/default.nix` | `tailscale-authkey` |

Per-agent secrets need **no Nix wiring at all**. Adding an agent to
`agents` automatically declares `hermes-<name>`, owns it by that user at mode
`0400`, and points their `environmentFile` at `/run/agenix/hermes-<name>`.
The only manual steps are adding a recipient rule and creating the file.

This is switched on by `services.hermes-agents.secretsBackend = "agenix"`.
The default is still `"envFile"` (`/etc/hermes/<name>.env`), so the module
works unchanged on a host that hasn't migrated.

## Who can decrypt what

**You never declare keys twice.** `secrets/secrets.nix` derives every recipient
from `hosts/homeserver/hermes_profiles.nix` — the `sshKeys` you already set per
agent. Adding an agent there automatically creates a rule for
`hermes-<name>.age` encrypted to that person plus the host.

| Secret | Recipients | Source |
|---|---|---|
| `hermes-karl.age` | karl + homeserver | derived from `agents.karl.sshKeys` |
| `hermes-joni.age` | joni + homeserver | derived from `agents.joni.sshKeys` |
| `tailscale-authkey.age` | admin + homeserver | declared in `secrets.nix` (belongs to no agent) |

`secrets.nix` is not a NixOS module — the agenix CLI plain-`import`s it
(`RULES=./secrets.nix`). That is what lets it import the host profile with dummy
module arguments: Nix is lazy, so reading `sshKeys` never forces `pkgs.elan` or
anything else in that file.

Each agent's secret is encrypted to **that person and the host only**. Karl is
deliberately *not* a recipient of Joni's secret: as administrator he can always
read the decrypted file as root, but keeping him off the recipient list means
the stored ciphertext is not his to open and the separation is visible in the
repo.

An agent with an empty `sshKeys` list would produce a secret nobody could edit,
so `secrets.nix` turns that into an explicit error rather than a confusing
agenix failure.

**Trade-off:** if Joni loses his laptop key, his secret is unrecoverable — it
must be recreated and the upstream credentials rotated. That is the right
trade for individually rotatable API tokens.

## Editing without a Nix machine

`agenix` is a wrapper around [`age`](https://github.com/FiloSottile/age), and
the `.age` files are plain age files — so any machine with the `age` binary can
read and write them (`brew install age`, `winget install age`,
`apt install age`). Verified: a file created with plain `age` decrypts with
`agenix` and vice versa.

```bash
# read
age -d -i ~/.ssh/id_ed25519 secrets/hermes-karl.age

# edit, then re-encrypt to the SAME recipients
age -d -i ~/.ssh/id_ed25519 secrets/hermes-karl.age > /tmp/s.env
$EDITOR /tmp/s.env
age -R recipients.txt -o secrets/hermes-karl.age /tmp/s.env && shred -u /tmp/s.env
```

`recipients.txt` is one public key per line, and **must** match the rule for
that file — miss the host key and the server can no longer decrypt it. Generate
it from the single source of truth instead of by hand:

```bash
nix-instantiate --json --eval --strict \
  -E '(import ./secrets/secrets.nix)."hermes-karl.age".publicKeys' \
  | jq -r '.[]' > recipients.txt
```

Where Nix *is* available (including macOS/WSL), prefer `nix run` — it reads the
rules itself, so recipients are always correct:

```bash
nix run github:ryantm/agenix -- -e secrets/hermes-karl.age
```

Editing on the homeserver works too (`agenix` is on its PATH), but note the
admin account there is **`homeserver`**, not `karl` — `karl` is a login-locked
agent account with no sudo. It also means putting your private key on the box,
which defeats keeping it on your laptop; treat it as a fallback.

---

## Step-by-step: Karl adds/edits his own secrets

On your laptop (the machine holding the private half of `karli@Karls-Surface`):

```bash
git clone git@github.com:Interorm/NixOS.git
cd NixOS

# Opens $EDITOR on the decrypted content, re-encrypts on save.
agenix -e secrets/hermes-karl.age
```

The content is `KEY=value`, exactly like the old `.env`:

```
OPEN_AI_API=sk-...
TELEGRAM_BOT_TOKEN=123456:ABC...
GITHUB_TOKEN=ghp_...
GMAIL_ADDRESS=hermes.agent.karl@gmail.com
GMAIL_PASSWORD=****************
```

Then:

```bash
git add secrets/hermes-karl.age
git commit -m "Update karl's agent secrets"
git push
sudo nixos-rebuild switch --flake .#homeserver   # or push + rebuild on the box
```

`agenix` is also on the homeserver's PATH, so you can do the same over SSH.

## Step-by-step: Joni adds/edits his own secrets

Joni never needs Karl, and Karl never sees the values.

**One-time:** confirm his key is in `secrets/secrets.nix` (it is —
`jonbrod@laptop`) and that he has the matching private key at
`~/.ssh/id_ed25519`.

```bash
# 1. get the repo
git clone git@github.com:Interorm/NixOS.git && cd NixOS

# 2. install the CLI ad-hoc (no system change needed)
nix run github:ryantm/agenix -- -e secrets/hermes-joni.age
#    ...or just `agenix -e secrets/hermes-joni.age` when on the homeserver

# 3. $EDITOR opens the decrypted file. Add KEY=value lines. Save & quit.

# 4. commit the CIPHERTEXT and open a PR
git checkout -b joni-secrets
git add secrets/hermes-joni.age
git commit -m "Update joni's agent secrets"
git push -u origin joni-secrets
```

Karl merges the PR **without being able to read it** — the diff is ciphertext.
On the next `nixos-rebuild switch`, Joni's agent picks up the new values.

If Joni is added to `agents` for the first time, one extra step comes first:
add the rule to `secrets/secrets.nix`
(`"hermes-joni.age".publicKeys = [ joni homeserver ];`) — that part is a normal
reviewable code change, and it contains no secret material.

## Step-by-step: a machine-level secret (e.g. Tailscale)

```bash
# 1. rule (already present for tailscale-authkey)
#    "tailscale-authkey.age".publicKeys = [ karl homeserver ];

# 2. create it -- paste the auth key, save, quit
agenix -e secrets/tailscale-authkey.age

# 3. uncomment the age.secrets block in
#    modules/services/secrets/default.nix, and the service that consumes it:
#      services.tailscale.authKeyFile =
#          config.age.secrets.tailscale-authkey.path;

# 4. commit + rebuild
```

Always consume a secret by **`.path`**, never by value — interpolating the
contents into a Nix string would copy it into the world-readable `/nix/store`.

---

## Migrating off `/etc/hermes/<agent>.env`

Nothing breaks when this lands: `secretsBackend` flips the default, but the
agent only reads the new path once the `.age` file exists. Do it one agent at
a time:

```bash
# 1. copy the existing plaintext in
sudo cat /etc/hermes/karl.env        # the values to carry over
agenix -e secrets/hermes-karl.age    # paste them, save

# 2. rebuild
sudo nixos-rebuild switch --flake .#homeserver

# 3. VERIFY before deleting anything
systemctl --user -M karl@ status hermes-agent
sudo ls -l /run/agenix/              # hermes-karl, owned by karl, 0400

# 4. only now remove the old file
sudo rm /etc/hermes/karl.env
```

A missing env file is a silent auth failure, not a loud one — verify the
gateway is actually up before deleting.

## Rotating and recovery

- **Change who can read a secret**: edit `secrets/secrets.nix`, then
  `agenix -r` (rekey). Needs a private key that can already decrypt it.
- **Host key regenerated** (reinstall, new disk): every secret must be rekeyed
  or activation fails to decrypt. The user key on each secret is what makes
  this recoverable.
- **All private keys for a secret lost**: unrecoverable by design. Rotate the
  underlying credential upstream and create a fresh secret.

## Threat model

- `.age` files are safe in a public repo, but that is still *harvest now,
  decrypt later* exposure. Prefer credentials you can rotate.
- agenix has not had a formal security audit (upstream says so plainly).
- `/run/agenix` is tmpfs — plaintext is gone on reboot and never hits disk.
- Root on the homeserver can read every decrypted secret. The per-user
  recipient split protects the *ciphertext at rest*, not against root.
