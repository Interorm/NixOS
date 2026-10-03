# FinTS / HBCI MCP server for Karl's Sparkasse Nienburg Girokonto —
# STRICTLY READ-ONLY.
#
# This file is only the registry snippet hermes/lib.nix exposes as `mcp.fints`
# (see hermes/users/karl.nix).  The application itself is built by
# ./fints/package.nix, which both this file and karl.nix import — the agent
# also needs `fints-enroll` on its PATH, and a registry snippet must evaluate
# to plain `{ command; args; env; }` data.
#
# All the code lives in this repo under hermes/mcp/fints/ (db.py,
# fints_client.py, mcp_server.py, enroll.py + tests), mirroring
# hermes/mcp/onedrive/ — the flake is the single source of truth, nothing at
# runtime points at a mutable checkout or a home path.  The one structural
# difference from ./onedrive.nix: that server is stdlib-only and single-file,
# this one needs `pkgs.python3Packages.fints` (5.0.0, already in this pinned
# nixpkgs — no overlay, no flake input) and imports sibling modules, so the
# whole package directory goes into the store.  Rationale in package.nix.
#
# SECURITY MODEL — read-only is a property of the CODE, not a flag or a
# permission the bank grants:
#   * The entire FinTS surface used is get_sepa_accounts() + get_transactions().
#     No transfer, no standing order, no sepa_transfer/HKCCS/HKDSE/pain.001
#     symbol exists anywhere in the package; test_harness.py AST-scans every
#     module to assert it, and that check was itself verified to fire by
#     injecting a transfer call and watching it fail.
#   * No MCP tool name contains transfer/send/pay/write/delete/update/insert.
#   * Every query tool opens SQLite with a `mode=ro` URI, so a query
#     physically cannot write — an INSERT really returns "attempt to write a
#     readonly database".
#   * The PIN is read from the environment, passed to the client, and never
#     logged, stored or returned; every exception message that leaves the
#     process is scrubbed of the PIN and the login name.  A rejected PIN is
#     never retried — repeats would lock the online banking.
#
# PSD2 / ~180-DAY RE-AUTH — expect one interactive step, twice a year:
# python-fints persists the bank-assigned system id
# (deconstruct(including_private=True)), and reusing it is what makes the bank
# apply the strong-customer-authentication exemption for *reads*, so the
# non-interactive sync needs no TAN.  Sparkasse Nienburg's own figure for that
# window is 180 days (not the commonly cited 90).  fints_status computes the
# countdown locally and never contacts the bank; once it lapses, fints_sync
# returns a structured {ok:false, error:"tan_required"} instead of hanging or
# crashing, and Karl re-enrols:
#
#     sudo -iu karl fints-enroll        # approve once in the S-pushTAN app
#
# That is a genuine one-time-per-window bootstrap (like the Google OAuth
# consent flow), NOT a step to repeat after every rebuild: the enrolment state
# lives in ~/.hermes/finance/fints_state.json (0600), which no rebuild touches.
#
# STATE: ~/.hermes/finance/ (0700), holding finance.db and fints_state.json.
# Created declaratively by a tmpfiles rule in hermes/users/karl.nix, outside
# the Nix store and outside the repo.
#
# CREDENTIALS AND BANK CONFIG — one source of truth, read identically by both
# consumers.  All five values the FinTS stack needs come from the agent's
# agenix-encrypted ~/.hermes/.env (/run/agenix/hermes-karl, 0400, owned by
# karl): Hermes loads that file and resolves ${VAR} in the env block below
# before spawning the server, and `fints-enroll` sources the very same file
# from a login shell.  The same mechanism ONEDRIVE_CLIENT_ID uses.
#
# Why the BLZ and the endpoint live there too, although neither is secret:
# they were previously stated as Nix literals here, which meant the MCP server
# got them and `fints-enroll` — the single bootstrap step of the whole feature
# — did not, because the env block is Hermes' spawn environment and is neither
# the user's shell environment nor part of .env.  A correctly configured box
# therefore failed with `missing required env var(s): FINTS_BLZ,
# FINTS_ENDPOINT`.  Declaring them once, in .env, is what makes the server and
# the enrolment CLI provably unable to disagree, and makes a future account or
# bank change one `agenix -e` away with no rebuild.  See secrets/README.md for
# the five-line walkthrough.
{ pkgs, ... }:
let
    app = import ./fints/package.nix { inherit pkgs; };
in {
    command = "${app}/bin/fints-mcp";
    args = [ ];

    env = {
        # What the server tells the model (and Karl) to run when the bank
        # wants a fresh pushTAN.  Packaged, there is no enroll.py in anyone's
        # working directory -- the script's own default instruction, `python3
        # enroll.py`, is unrunnable here, and an unrunnable instruction in a
        # twice-a-year recovery path is worse than no instruction.  Declared
        # in the same file that puts the wrapper on the agent's PATH
        # (hermes/users/karl.nix imports the same derivation), so the two
        # cannot drift.
        FINTS_ENROLL_CMD = "fints-enroll";

        # The labeling engine's two knobs (categorize.py).  Both already
        # default to exactly these values in the Python, so this changes no
        # behaviour -- it makes the contract declarative, which matters most
        # for the model: the labeling pass must stay on Gemma4-E4B, which is
        # always-on, and must never be pointed at Qwen3.8-27B, which sits
        # behind Wake-on-LAN and would boot Karl's workstation from the daily
        # cron.  The gateway must stay loopback; categorize.py._assert_local()
        # refuses a non-local host outright, so transaction data cannot reach
        # a cloud provider even if this line is edited.
        FINANCE_LABEL_MODEL = "Gemma4-E4B";
        HERMES_GATEWAY = "http://127.0.0.1:8080/v1";

        # Written literally (note the backslash) and resolved by Hermes from
        # .env at runtime, so nothing here reaches the world-readable
        # /nix/store -- which is required for the three secrets and is what
        # keeps the other two from becoming a second declaration.
        #
        # FINTS_USER_ID is the *Anmeldename* (online-banking login name), NOT
        # the account number or the IBAN.  FINTS_PRODUCT_ID is the FinTS
        # Produkt-ID: python-fints >= 4 makes it a mandatory constructor
        # argument with no default, so it is required even though it is only
        # semi-secret.  FINTS_BLZ and FINTS_ENDPOINT are published facts about
        # the bank and are not secret at all; they are here because this is
        # the one place both the server and `fints-enroll` read.  See
        # secrets/README.md and hermes/mcp/fints/README.md.
        FINTS_BLZ = "\${FINTS_BLZ}";
        FINTS_ENDPOINT = "\${FINTS_ENDPOINT}";
        FINTS_USER_ID = "\${FINTS_USER_ID}";
        FINTS_PIN = "\${FINTS_PIN}";
        FINTS_PRODUCT_ID = "\${FINTS_PRODUCT_ID}";
    };
}
