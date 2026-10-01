# ADR 0001 — Google access as declarative per-account capabilities

- **Status:** proposed
- **Date:** 2026-10-01
- **Supersedes:** the `services.hermes-agents.agents.<n>.googleWorkspace.enable`
  boolean (kept working as a deprecated alias)

## Context

Google access for a Hermes agent was a single boolean. `googleWorkspace.enable =
true` meant *all* of Gmail, Calendar, Drive, Docs, Sheets and Contacts, including
sending and trashing mail, for one implicit account. There was no way to express
the actual requirement that prompted this: **read and auto-label Karl's personal
mail, and never send as him.**

Four facts about Google's model determine what a declarative design can and cannot
promise. Each was verified rather than assumed.

### 1. Gmail couples modify and send

Computed from the live Gmail v1 discovery document: the set of Gmail scopes that
permit `users.messages.modify` but **not** `users.messages.send` is **empty**.

| Operation | Narrowest scope | Grants send? |
|---|---|---|
| read, `labels.list`, `filters.list/get` | `gmail.readonly` | no |
| `labels.create/update/delete` | `gmail.labels` | no |
| `filters.create/delete` (labeling *rules*) | `gmail.settings.basic` | no |
| `messages.modify`, `batchModify`, `trash` | `gmail.modify` | **YES** |
| `messages.send` | `gmail.send`, `gmail.compose`, `gmail.modify` | yes |
| `messages.delete` (permanent) | `https://mail.google.com/` | yes |

So "label mail that has already arrived" costs send access, permanently, with no
workaround. "Label mail arriving from now on" costs nothing, via a server-side
Gmail filter — which also keeps working while the agent is offline.

This is the single most consequential fact in the design, and it is a property of
*the data*, so it is documented in the capability table itself rather than in a
README somebody might not open.

### 2. The scope ceiling is per PROJECT, not per client

The Google Auth Platform **Data Access** page — where the scope list lives — is a
**project-level** config shared by every OAuth client in the project. A "read-only
client" inside a project that also lists write scopes enforces **nothing**: a
client cannot have a narrower ceiling than its project.

The only hard, independent ceiling is a **separate Cloud project**, with its own
client secret.

### 3. Enforcement lives in the token

Google validates **every API call** against the scopes baked into the token minted
at the consent screen, returning `403 insufficient_permission` otherwise.

Consequences, both load-bearing:

- The **token is the security boundary.** It holds even if the agent is confused,
  mistaken, or acting on injected text in an email it just read.
- Nix config, the generated manifest and the shipped skill are **advisory**. They
  buy correct behaviour and comprehensible errors, not safety. In particular,
  *shrinking a declared capability list does not shrink an existing token* — the
  account must re-consent.

### 4. Testing mode caps refresh tokens at ~7 days

The fleet's OAuth app is in publishing status **Testing** with an external user
type, so Google issues refresh tokens that expire after about 7 days for users
**external to the app's own project**. The agent's own mailbox is the project's
account and survives; a human's personal Gmail does not. Every Gmail scope is
sensitive or restricted, so Production requires Google verification.

Nix cannot fix this. It can make it visible before it bites.

### Mechanics that shaped the implementation

- The vendored `google-workspace` skill's `google_api.py` is **hub-managed and
  read-only**, not in this repo, and has **no `--account` flag**. It computes
  `TOKEN_PATH = HERMES_HOME / "google_token.json"` via the skill's own
  `_hermes_home.py`, which reads `HERMES_HOME` from the environment and falls back
  to `~/.hermes`. Proven live: `HERMES_HOME=<empty dir>` → "Not authenticated";
  unset → Karl's real label list. **A per-account `HERMES_HOME` is therefore the
  entire multi-account mechanism**, with no patch and no upstream change.
- An existing token embeds `client_id`, `client_secret` **and** `refresh_token`,
  and `google_api.py` only ever calls `Credentials.from_authorized_user_file`. So
  the client secret is a **setup-time input, not a runtime dependency**, and
  relocating a token file preserves access with no re-consent.
- The vendored `setup.py` pins exact package versions and calls `pip install` on
  mismatch, which cannot work against a read-only store. The auth CLI must
  therefore implement the OAuth flow itself.

## Decision

**Model Google access as a set of named accounts, each holding a list of named
capabilities. Derive everything else.**

```
hermes/google/capabilities.nix     capability name -> [ scope URL ]   (plain data)
hermes/google/default.nix          resolution + enum type             (lib only)
hermes/google/wrappers.nix         the generated CLIs + manifest      (needs pkgs)
hermes/google/google_accounts.py   the functional half
```

Five specific choices:

1. **Capability bundles are the vocabulary; scope URLs appear in exactly one
   file.** A user file names `"mail.read"`, never
   `https://www.googleapis.com/auth/gmail.readonly`. An unknown capability is an
   **eval error naming the valid set**, produced by `lib.types.enum` rather than a
   hand-written assertion.

2. **Accounts are first-class, not implicit.** `google.accounts.<name>` carries
   `capabilities`, `address`, `purpose`, `publishing` and `project`; `scopes` and
   `tokenPath` are `readOnly` and derived. The name is a local handle — it names
   the token directory, the generated command, and the `--account` selector.

3. **`purpose` is prose the agent reads, co-located with the policy.** Capabilities
   say what an account *can* do; `purpose` says what it is *for*, and the two are
   not the same. Keeping it in the `.nix` file means it cannot drift from the
   capability list it qualifies. (See "open questions".)

4. **Scopes are baked into generated wrappers, not passed as arguments.** The
   agent is the one running these commands. There is deliberately no `--scope`
   flag: the only way to change what the agent may request is a reviewed commit.
   This is a correctness property, not a hard boundary — an agent with shell access
   can always call python directly. The hard boundary is the token.

5. **One fleet-wide client secret, fanned out per agent.** The plaintext is a
   single app credential, byte-identical for every agent, identifying the *OAuth
   application* rather than a person. `secrets/google-client.age` is a
   machine-level secret (recipients: admin + host); `age.secrets` declares one
   entry per google-enabled agent pointing at that same `file`, so each agent still
   gets its own `0400` decryption at `/run/agenix/google-<agent>`. Enabling Google
   for a new agent needs no new `.age` file and no new recipient rule.

### The reproducibility asymmetry, stated plainly

| | Client secret | OAuth token |
|---|---|---|
| Scope | one per *application*, fleet-wide | one per *account* |
| Sensitivity | **weakly** secret — a desktop client's secret is not a real secret; PKCE protects the flow | **genuinely dangerous** — holds a refresh token |
| Reproducible | **yes** — agenix ciphertext in the repo | **no** — only an interactive human consent mints one |
| Where | `/run/agenix/google-<agent>`, tmpfs, 0400 | `~/.hermes/google/<account>/google_token.json`, 0600 |

The *less* sensitive half is the reproducible one. That is uncomfortable and
unavoidable, and it is why the one-time consent per account is a legitimate
bootstrap rather than a gap in the declarative story: nothing must be re-run after
a rebuild.

## Alternatives considered

| Alternative | Rejected because |
|---|---|
| Keep the boolean, add `extraScopes` | Scope URLs leak into user files; no vocabulary; no eval-time validation; the Gmail modify/send coupling stays invisible. |
| Scope lists directly in `google.accounts.<n>.scopes` | Same, plus every reviewer must decode URLs to see what an account may do. |
| A second OAuth **client** for read-only access | Enforces nothing: the ceiling is per project (fact 2). Would have *looked* like a boundary. |
| A separate Cloud **project** for read-only | The only real independent ceiling — but costs a second project and a second client secret. Left as an open question rather than decided unilaterally. |
| One `.age` per agent for the client secret (status quo) | N identical ciphertexts to rekey when the app credential rotates, plus a new rule per agent, for a credential that is not personal data. |
| One `.age` + a shared Unix group | Widens who can read the plaintext and adds a group to the system's vocabulary. The fan-out costs nothing but a decrypt. |
| Patch the vendored `google_api.py` to take `--account` | It is hub-managed and read-only; a fork would drift from upstream silently. `HERMES_HOME` is a documented contract and sufficient. |
| Copy the skill into `~/.hermes/skills/` | The hermes module deliberately does not manage that tree so a rebuild cannot wipe agent-authored skills. `settings.skills.external_dirs` is the sanctioned read-only hatch. |
| Shell out to the vendored `setup.py` | Exact version pins + `pip install` on mismatch; cannot work on NixOS. |

## Consequences

**Good**

- "Read and label but never send" is expressible, and the cost of the alternative
  (`mail.write` ⇒ send) is stated where the decision is made.
- Adding an account is one block in one file: scopes, token home, a generated
  command, a manifest entry and a `0400` client-secret decryption all follow.
- A typo in a capability name fails the build with the valid set printed.
- A `403` becomes the configuration fact that caused it, naming the file and
  attribute to change and warning that Nix alone changes nothing until re-consent.
- `hermes-google-status` shows declared vs **actually granted** side by side, which
  is the only way the fact-3 gap is visible.
- The deprecated boolean still evaluates to the same 8 scopes the vendored
  `setup.py` requested, so migration is a `mv` with no re-consent.

**Costs and limits**

- One interactive OAuth consent per account, and under Testing a re-consent roughly
  weekly for accounts external to the project. Not repeated after a rebuild.
- Nothing here is enforcement. An account declared `mail.read` whose token was
  minted with `gmail.modify` can still modify; only `hermes-google-status` will say
  so.
- The capability table is a human judgement about Google's API. When Google changes
  a scope's meaning, the table is wrong until somebody re-checks it against the
  discovery document.
- `publishing` and `project` are documentation of Cloud Console state that Nix
  cannot read or verify. They can go stale.

## Open questions (Karl's calls)

1. `purpose` prose in `.nix` (co-located, cannot drift) vs keeping prose out of
   config files (same text in the repo skill, two files to sync).
2. Mail tier for the personal account: `mail.read + mail.labels + mail.rules` (no
   send, server-side auto-labeling, survives the agent being offline) vs adding
   `mail.write` for backfill (permanently includes send). **Recommendation: the
   former.** This PR does not add a personal account at all.
3. Testing vs Production for the personal account: ~7-day refresh tokens vs Google
   verification for sensitive scopes.
4. A separate Cloud project for a hard no-send ceiling — the only real enforcement
   boundary, at the cost of a second project and client secret.

## References

- `hermes/google/capabilities.nix` — the table, with the modify⇒send warning next
  to the data
- `hermes/google/WRITING-WRAPPERS.md` — how the generated wrappers are built
- `hermes/skills/google-oauth/SKILL.md` — the advisory layer the agent reads
- `secrets/README.md` — the client-secret / token asymmetry, operationally
