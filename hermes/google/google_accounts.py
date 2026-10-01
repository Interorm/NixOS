#!/usr/bin/env python3
"""Per-account Google OAuth for the Hermes fleet: consent, status, API passthrough.

This file is the functional half of hermes/google/.  Nix bakes the policy (which
accounts exist, which scopes each may request, where each token lives) into a
JSON manifest in the Nix store and points this script at it with
HERMES_GOOGLE_MANIFEST.  Nothing here reads a capability list, a scope URL or a
path from the environment or from a command-line argument, so an agent running
these commands cannot widen its own grant: the only lever it has is *which
declared account* to use.

Three subcommands, each exposed as its own generated wrapper (see wrappers.nix):

  auth <account> [redirect-url]
      No redirect-url: print the consent URL built from the account's baked
      scopes, plus which Google account to pick and what to paste back.
      With one: exchange the code, write the token 0600, report granted-vs-
      declared, print the status line.

  status [account ...] [--json]
      Every account: declared capabilities, live token state, scopes actually
      granted, the publishing caveat, the purpose prose, and -- derived from
      the capabilities it does NOT have -- a `cannot:` line.  For an
      unauthorised account it prints the exact next command.

  api <account> <service> [args ...]
      Sets HERMES_HOME to that account's token home and execs the vendored
      google-workspace skill's google_api.py.  That env var is the ENTIRE
      multi-account mechanism: google_api.py resolves its token path as
      `HERMES_HOME/google_token.json` via the skill's own _hermes_home.py, so a
      per-account HERMES_HOME is a per-account token with no patch to the
      vendored skill (which is hub-managed and read-only).  A
      `403 insufficient_permission` from Google is rewritten into the
      configuration fact that caused it.

WHY NOT the vendored skill's own setup.py: it carries exact version pins
(google-api-python-client==2.194.0, ...) and calls `pip install` when the
interpreter does not match.  On NixOS that cannot work -- the store is
read-only -- and the gate fails even though the API client itself is fine.
This script has no such gate; its interpreter is pinned by Nix.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

# --------------------------------------------------------------------------- #
# Manifest access.  The manifest is a Nix store path: content-addressed,
# world-readable, immutable, and re-derived on every rebuild from the flake.
# Treat it as read-only policy.
# --------------------------------------------------------------------------- #

MANIFEST_ENV = "HERMES_GOOGLE_MANIFEST"
# Name google_api.py insists on inside HERMES_HOME.  Verified in the vendored
# skill: `TOKEN_PATH = HERMES_HOME / "google_token.json"`.  Nix derives the same
# name; this constant exists so the two can be diffed, not so it can be changed.
TOKEN_BASENAME = "google_token.json"
PENDING_BASENAME = "oauth_pending.json"


def die(msg: str, code: int = 1) -> NoReturn:
    print(msg, file=sys.stderr)
    sys.exit(code)


def load_manifest() -> dict:
    raw = os.environ.get(MANIFEST_ENV, "").strip()
    if not raw:
        die(
            f"ERROR: {MANIFEST_ENV} is not set.\n"
            "  This command is meant to be run through the Nix-generated wrapper\n"
            "  (hermes-google-auth / hermes-google-status / hermes-gmail), which\n"
            "  bakes the manifest store path in."
        )
    try:
        return json.loads(Path(raw).read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        die(f"ERROR: cannot read the Google account manifest at {raw}: {exc}")


def pick_account(man: dict, name: str) -> dict:
    accounts = man["accounts"]
    if name not in accounts:
        known = ", ".join(sorted(accounts)) or "(none declared)"
        die(
            f"ERROR: no Google account named '{name}'.\n"
            f"  Declared accounts: {known}\n"
            "  Accounts are declared in hermes/users/<agent>.nix under\n"
            "    services.hermes-agents.agents.<agent>.google.accounts.<name>\n"
            "  Run hermes-google-status to see them with their purpose."
        )
    acct = dict(accounts[name])
    acct["name"] = name
    return acct


# --------------------------------------------------------------------------- #
# Token inspection.  Read-only, no network: a status call must work offline and
# must never refresh (refreshing is a side effect, and in Testing mode a
# refresh can be the thing that fails).
# --------------------------------------------------------------------------- #


def token_state(acct: dict) -> dict:
    path = Path(acct["tokenPath"])
    if not path.exists():
        return {"state": "missing", "granted": [], "expiry": None}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return {"state": f"unreadable ({exc})", "granted": [], "expiry": None}

    granted = data.get("scopes") or []
    if isinstance(granted, str):
        granted = granted.split()
    expiry = data.get("expiry")

    state = "ok"
    if not data.get("refresh_token"):
        # Without a refresh token the credential dies at the access token's
        # expiry and cannot come back -- the account needs a fresh consent.
        state = "no-refresh-token"
    return {"state": state, "granted": sorted(granted), "expiry": expiry}


def mode_warning(path: Path) -> "str | None":
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        return None
    if mode & 0o077:
        return f"token is mode {mode:04o}; it holds a refresh token and should be 0600"
    return None


# --------------------------------------------------------------------------- #
# status
# --------------------------------------------------------------------------- #


def cannot_line(acct: dict, man: dict) -> str:
    """Derive what this account CANNOT do from the capabilities it lacks.

    Derived, not written: the remediation table in hermes/google/default.nix is
    the single source, so a new capability shows up here automatically.
    """
    have = set(acct["capabilities"])
    ref = man["reference"]
    out = []
    for verb, info in sorted(ref["remediation"].items()):
        if not have.intersection(info["needs"]):
            out.append(verb)
    return ", ".join(out) if out else "(nothing in the remediation table)"


def cmd_status(man: dict, argv: list[str]) -> int:
    want_json = "--json" in argv
    names = [a for a in argv if not a.startswith("-")]
    accounts = man["accounts"]
    unknown = [n for n in names if n not in accounts]
    if unknown:
        die(
            f"ERROR: unknown account(s): {', '.join(unknown)}\n"
            f"  Declared: {', '.join(sorted(accounts)) or '(none)'}"
        )
    selected = names or sorted(accounts)

    if want_json:
        payload = {}
        for name in selected:
            acct = pick_account(man, name)
            payload[name] = {**acct, "token": token_state(acct)}
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    if not selected:
        print("No Google accounts are declared for this agent.")
        print("Declare one in hermes/users/<agent>.nix:")
        print("  google.accounts.<name>.capabilities = [ \"mail.read\" ];")
        return 0

    print(f"Google accounts for agent '{man['agent']}'")
    print(f"  client secret (fleet-shared, agenix): {man['clientSecretFile']}")
    print(f"  manifest: {os.environ.get(MANIFEST_ENV)}")
    print()

    rows = []
    for name in selected:
        acct = pick_account(man, name)
        tok = token_state(acct)
        rows.append((acct, tok))

    # max against the header so the column never collapses narrower than
    # "ACCOUNT" and the two rows stay aligned.
    width = max([len(a["name"]) for a, _ in rows] + [len("ACCOUNT")])
    print(f"{'ACCOUNT'.ljust(width)}  {'ADDRESS'.ljust(32)}  TOKEN")
    for acct, tok in rows:
        addr = acct.get("address") or "(not pinned)"
        print(f"{acct['name'].ljust(width)}  {addr[:32].ljust(32)}  {tok['state']}")
    print()

    for acct, tok in rows:
        name = acct["name"]
        print(f"--- {name} " + "-" * max(0, 68 - len(name)))
        print(f"  address      : {acct.get('address') or '(not pinned -- pick carefully at the consent screen)'}")
        print(f"  capabilities : {' '.join(acct['capabilities']) or '(none)'}")
        print(f"  cannot       : {cannot_line(acct, man)}")
        print(f"  token        : {acct['tokenPath']}  [{tok['state']}]")
        if tok["expiry"]:
            print(f"  access token expiry: {tok['expiry']}  (refreshed automatically)")

        declared = set(acct["scopes"])
        granted = set(tok["granted"])
        if tok["state"] == "missing":
            print("  scopes       : declared only (no token yet)")
            for s in acct["scopes"]:
                print(f"                 - {s}")
            print()
            print(f"  NEXT STEP:  hermes-google-auth {name}")
            print("              (one-time interactive consent; NOT repeated after a rebuild)")
        else:
            missing = sorted(declared - granted)
            extra = sorted(granted - declared)
            print(f"  scopes       : {len(granted)} granted / {len(declared)} declared")
            for s in sorted(granted):
                tag = "  (NOT declared in Nix)" if s in extra else ""
                print(f"                 + {s}{tag}")
            for s in missing:
                print(f"                 - {s}   MISSING -- consent was partial or predates this config")
            if missing:
                print(f"  ACTION: re-consent to pick the missing scopes up:  hermes-google-auth {name}")
            if extra:
                print(
                    "  NOTE: the token grants more than Nix declares.  Google enforces the\n"
                    "        TOKEN's scopes, not this config -- shrinking `capabilities` does\n"
                    f"        not shrink an existing token.  Re-run `hermes-google-auth {name}`\n"
                    "        to mint a token that matches, or revoke the grant at\n"
                    "        https://myaccount.google.com/permissions"
                )
            warn = mode_warning(Path(acct["tokenPath"]))
            if warn:
                print(f"  /!\\ {warn}")

        if acct.get("publishing") == "testing":
            print(
                "  /!\\ publishing=testing: this OAuth app is in Testing, so Google issues\n"
                "      refresh tokens that EXPIRE AFTER ~7 DAYS for users external to the\n"
                "      app's own project.  Expect to re-consent weekly until the app is\n"
                "      verified for Production (all Gmail scopes are sensitive/restricted,\n"
                "      so Production requires Google review)."
            )
        if acct.get("project"):
            print(f"  cloud project: {acct['project']}  (independent scope ceiling)")
        print(f"  purpose      :")
        for line in (acct.get("purpose") or "(none stated)").strip().splitlines():
            print(f"      {line.rstrip()}")
        print()

    print("Enforcement note: Google validates every API call against the scopes in the")
    print("TOKEN. This config, this manifest and the skill are ADVISORY -- they buy correct")
    print("behaviour and clear errors, not safety. The token is the security boundary.")
    return 0


# --------------------------------------------------------------------------- #
# auth
# --------------------------------------------------------------------------- #


def _flow(acct: dict, man: dict, **kw):
    from google_auth_oauthlib.flow import Flow

    secret = Path(man["clientSecretFile"])
    if not secret.exists():
        die(
            f"ERROR: OAuth client secret not found at {secret}\n"
            "  Under the agenix backend this is decrypted at activation from\n"
            "  secrets/google-client.age.  If the path is missing, the host has not\n"
            "  activated the secret: check `ls -l /run/agenix/` and the age.secrets\n"
            "  entry in modules/services/hermes/hermes.nix."
        )
    return Flow.from_client_secrets_file(
        str(secret),
        scopes=acct["scopes"],
        redirect_uri=man["redirectUri"],
        **kw,
    )


def cmd_auth(man: dict, argv: list[str]) -> int:
    if not argv:
        die(
            "usage: hermes-google-auth <account> [redirect-url]\n"
            f"  accounts: {', '.join(sorted(man['accounts'])) or '(none declared)'}"
        )
    acct = pick_account(man, argv[0])
    home = Path(acct["tokenHome"])
    home.mkdir(parents=True, exist_ok=True)
    try:
        home.chmod(0o700)
    except OSError:
        pass
    pending = home / PENDING_BASENAME

    if len(argv) == 1:
        flow = _flow(acct, man, autogenerate_code_verifier=True)
        url, state = flow.authorization_url(access_type="offline", prompt="consent")
        pending.write_text(
            json.dumps({"state": state, "code_verifier": flow.code_verifier}, indent=2),
            encoding="utf-8",
        )
        pending.chmod(0o600)

        print(f"One-time consent for Google account '{acct['name']}'.")
        print()
        print(f"  1. Open this URL and sign in as: {acct.get('address') or '<the right account -- none pinned in Nix>'}")
        print()
        print(url)
        print()
        print("  2. Grant these and only these:")
        for cap in acct["capabilities"]:
            print(f"       {cap}")
        for s in acct["scopes"]:
            print(f"       - {s}")
        print()
        print(f"  3. Google redirects to {man['redirectUri']} , which WILL FAIL TO LOAD.")
        print("     That is expected and correct -- nothing is listening there, and nothing")
        print("     needs to be. The authorization code is in the URL bar.")
        print()
        print("  4. Copy the WHOLE failed URL from the address bar and run:")
        print()
        print(f"       hermes-google-auth {acct['name']} '<paste the whole URL>'")
        print()
        print("This is a one-time bootstrap per account. It is NOT repeated after a")
        print("nixos-rebuild: the token persists in the agent's home, outside the store.")
        return 0

    raw = argv[1]
    if not pending.exists():
        die(
            f"ERROR: no pending consent session for '{acct['name']}'.\n"
            f"  Run `hermes-google-auth {acct['name']}` first to get a fresh URL."
        )
    try:
        sess = json.loads(pending.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        die(f"ERROR: pending session at {pending} is unreadable: {exc}")

    code, returned_state = raw, None
    if raw.startswith("http"):
        from urllib.parse import parse_qs, urlparse

        q = parse_qs(urlparse(raw).query)
        if "error" in q:
            die(
                f"ERROR: Google returned an error instead of a code: {q['error'][0]}\n"
                "  'access_denied' usually means the consent screen was cancelled, or the\n"
                "  signed-in account is not a Test user on the OAuth app (Testing mode)."
            )
        if "code" not in q:
            die(
                "ERROR: the pasted URL has no 'code' parameter.\n"
                "  Paste the WHOLE redirect URL from the browser's address bar, including\n"
                f"  the {man['redirectUri']}?... prefix."
            )
        code = q["code"][0]
        returned_state = (q.get("state") or [None])[0]

    if returned_state and returned_state != sess["state"]:
        die(
            "ERROR: OAuth state mismatch -- the pasted URL belongs to a different consent\n"
            f"  session. Re-run `hermes-google-auth {acct['name']}` for a fresh URL."
        )

    flow = _flow(acct, man, state=sess["state"], code_verifier=sess["code_verifier"])
    # Partial consent (the user unticks a scope) otherwise raises inside
    # oauthlib's strict scope check with a message that looks like a config bug.
    # We would rather store exactly what was granted and SAY what is missing.
    os.environ["OAUTHLIB_RELAX_TOKEN_SCOPE"] = "1"
    try:
        flow.fetch_token(code=code)
    except Exception as exc:  # noqa: BLE001
        die(
            f"ERROR: token exchange failed: {exc}\n"
            "  Common causes:\n"
            "    * the code was already used (each code is single-use -- get a fresh URL)\n"
            "    * more than a few minutes elapsed (codes expire quickly)\n"
            "    * redirect_uri mismatch: the OAuth client must be of type 'Desktop app'\n"
            f"      for {man['redirectUri']} to be accepted"
        )

    creds = flow.credentials
    payload = json.loads(creds.to_json())
    payload.setdefault("type", "authorized_user")
    granted = list(getattr(creds, "granted_scopes", None) or [])
    # Store ONLY the scopes actually granted: a token claiming scopes it does
    # not have fails its first refresh with an opaque invalid_scope.
    payload["scopes"] = granted or list(acct["scopes"])

    token = Path(acct["tokenPath"])
    token.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    token.chmod(0o600)
    pending.unlink(missing_ok=True)

    declared = set(acct["scopes"])
    got = set(payload["scopes"])
    print(f"OK: token written to {token} (0600)")
    if not payload.get("refresh_token"):
        print(
            "/!\\ NO REFRESH TOKEN was issued. The access token expires within the hour\n"
            "    and cannot be renewed. Re-run with a fresh URL; if it keeps happening,\n"
            "    revoke the app at https://myaccount.google.com/permissions first so\n"
            "    Google issues a new offline grant."
        )
    missing = sorted(declared - got)
    if missing:
        print("/!\\ PARTIAL CONSENT -- declared but NOT granted:")
        for s in missing:
            print(f"      - {s}")
        print("    Calls needing those will fail with 403 insufficient_permission.")
    extra = sorted(got - declared)
    if extra:
        print("/!\\ granted MORE than declared (a previous grant is being carried forward):")
        for s in extra:
            print(f"      + {s}")
    print()
    return cmd_status(man, [acct["name"]])


# --------------------------------------------------------------------------- #
# api passthrough
# --------------------------------------------------------------------------- #


def find_google_api(man: dict) -> Path:
    """Locate the vendored google-workspace skill's google_api.py at RUNTIME.

    It is hub-managed under the agent's ~/.hermes/skills/ -- NOT a store path and
    NOT in this repo -- so it cannot be baked in, and a copy would fork from
    upstream silently.  Resolution order:

      1. $HERMES_GOOGLE_API            explicit override (testing)
      2. <agent hermes home>/skills/   the normal location, baked by Nix
      3. $HOME/.hermes/skills/         fallback when run as another user
    """
    override = os.environ.get("HERMES_GOOGLE_API", "").strip()
    if override:
        p = Path(override)
        if not p.exists():
            die(f"ERROR: HERMES_GOOGLE_API={override} does not exist.")
        return p

    rel = Path("skills/productivity/google-workspace/scripts/google_api.py")
    candidates = [Path(man["hermesHome"]) / rel, Path.home() / ".hermes" / rel]
    for c in candidates:
        if c.exists():
            return c
    die(
        "ERROR: the google-workspace skill's google_api.py was not found.\n"
        "  Looked in:\n"
        + "".join(f"    {c}\n" for c in candidates)
        + "  That script is managed by the Hermes skill hub, not by this flake, so a\n"
        "  rebuild cannot install it. Install/sync the `google-workspace` skill for\n"
        f"  agent '{man['agent']}' (hermes skills sync), or point HERMES_GOOGLE_API at it."
    )


# Gmail subcommand -> the verb key in the remediation table.  Used only to pick
# a helpful remediation sentence when Google says 403; the authoritative mapping
# lives in hermes/google/default.nix.
VERB_BY_SUBCOMMAND = {
    "send": "send",
    "reply": "send",
    "label": "label",
    "labels": "label-manage",
    "filters": "rules",
    "search": "read",
    "get": "read",
}


def translate_403(acct: dict, man: dict, service: str, sub: str, stderr: str) -> str:
    verb = VERB_BY_SUBCOMMAND.get(sub, sub)
    ref = man["reference"]["remediation"].get(verb)
    lines = [
        f"ERROR: account '{acct['name']}' is not permitted to {service} {sub} "
        "(Google returned 403 insufficient_permission).",
        f"  Declared capabilities: {' '.join(acct['capabilities']) or '(none)'}",
    ]
    if ref:
        lines.append(f"  '{verb}' needs one of: {' '.join(ref['needs'])}")
        lines.append(f"  {ref['note']}")
    else:
        lines.append(
            "  No capability in hermes/google/capabilities.nix maps to that operation; "
            "see that file for the full table."
        )
    lines += [
        f"  To change it: hermes/users/{man['agent']}.nix ->",
        f"      services.hermes-agents.agents.{man['agent']}.google.accounts.{acct['name']}.capabilities",
        "  Then re-run the one-time consent so the TOKEN carries the new scopes:",
        f"      hermes-google-auth {acct['name']}",
        "  (Google enforces the token's scopes, not this config -- editing Nix alone",
        "   changes nothing until the account re-consents.)",
    ]
    if stderr.strip():
        lines.append("  --- Google's own message ---")
        lines += [f"  {ln}" for ln in stderr.strip().splitlines()]
    return "\n".join(lines)


def cmd_api(man: dict, argv: list[str]) -> int:
    if len(argv) < 2:
        die("usage: <wrapper> --account <name> <service> [args ...]")
    acct = pick_account(man, argv[0])
    rest = argv[1:]
    service, sub = rest[0], (rest[1] if len(rest) > 1 else "")

    token = Path(acct["tokenPath"])
    if not token.exists():
        die(
            f"ERROR: account '{acct['name']}' has no token yet -- it has never consented.\n"
            f"  Expected at: {token}\n"
            f"  Run the one-time consent:  hermes-google-auth {acct['name']}\n"
            f"  Or see every account:      hermes-google-status"
        )

    script = find_google_api(man)
    home = Path(acct["tokenHome"])

    env = dict(os.environ)
    # THE multi-account mechanism, in one line.  google_api.py derives
    # TOKEN_PATH = HERMES_HOME/"google_token.json" through the skill's own
    # _hermes_home.py, which reads this variable and falls back to ~/.hermes --
    # a documented contract, not a hack.  No --account flag exists upstream and
    # none is needed.
    env["HERMES_HOME"] = str(home)
    env.pop("HERMES_GOOGLE_MANIFEST", None)

    proc = subprocess.run(
        [sys.executable, str(script), *rest],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.stdout:
        sys.stdout.write(proc.stdout)
    blob = (proc.stderr or "") + (proc.stdout or "")
    if proc.returncode != 0 and (
        "insufficient" in blob.lower()
        or "insufficientPermissions" in blob
        or ("403" in blob and "scope" in blob.lower())
    ):
        print(translate_403(acct, man, service, sub, proc.stderr or ""), file=sys.stderr)
        return 77
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    return proc.returncode


# --------------------------------------------------------------------------- #

USAGE = """usage: google_accounts.py {auth|status|api} ...

Normally invoked through the Nix-generated wrappers, which bake the manifest in:
  hermes-google-auth <account> [redirect-url]
  hermes-google-status [account ...] [--json]
  hermes-gmail --account <name> <subcommand> ...
  hermes-google-<account> <service> <subcommand> ...
"""


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd not in ("auth", "status", "api"):
        die(USAGE, 2)
    man = load_manifest()
    if cmd == "auth":
        return cmd_auth(man, rest)
    if cmd == "status":
        return cmd_status(man, rest)
    return cmd_api(man, rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
