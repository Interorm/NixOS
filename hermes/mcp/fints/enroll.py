#!/usr/bin/env python3
"""One-time interactive pushTAN enrollment for Sparkasse Nienburg. READ-ONLY.

Karl runs this by hand, once, and again whenever the ~180-day PSD2 window
lapses. It performs exactly one privileged act — approving a *read* of the
account under strong customer authentication — and persists the resulting
FinTS state so the non-interactive cron sync can read TAN-free afterwards.

Why this exists
---------------
python-fints keeps the bank-assigned system id plus the BPD/UPD in the client
object. ``deconstruct(including_private=True)`` serialises that; restoring it
with ``from_data=`` on the next run reuses the SAME system id, which is what
lets the bank apply the PSD2 SCA exemption to balance/statement reads. Without
it, every sync would demand a fresh pushTAN approval and cron would be
impossible.

Decoupled (pushTAN) flow — verified against python-fints 5.0.0
--------------------------------------------------------------
  * A TAN demand is a ``NeedTANResponse`` RETURN value, never an exception
    (the class does not subclass BaseException).
  * For a decoupled mechanism ``send_tan(response, "")`` IGNORES the tan
    argument and RE-RETURNS a ``NeedTANResponse`` while the approval is still
    pending (bank response code 3956), so it must be called in a polling loop
    until it returns something else.

Usage:
    python3 enroll.py            # interactive; prompts nothing, just waits
    python3 enroll.py --status   # show enrollment state, contact nothing
Exit 0 = enrolled (state written), 1 = failed/aborted.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
import fints_client as fc  # noqa: E402

POLL_INTERVAL = 5      # seconds between decoupled approval polls
POLL_TIMEOUT = 300     # give up after 5 minutes of no approval


def out(*a):
    print(*a, flush=True)


def _mechanism_name(param):
    """Human label for a TwoStepParameters object.

    Field names verified against python-fints 5.0.0 formals.py: every
    TwoStepParameters version carries ``name`` and ``tech_id``
    ("Technische Identifikation TAN-Verfahren").
    """
    name = str(getattr(param, "name", "") or "").strip()
    tech = str(getattr(param, "tech_id", "") or "").strip()
    if name and tech:
        return f"{name} ({tech})"
    return name or tech or "(unnamed)"


def _supports_decoupled(param):
    """True when the HITANS parameters describe a decoupled-capable mechanism.

    IMPORTANT (verified in python-fints 5.0.0): whether a given challenge is
    actually decoupled is decided by the BANK AT RUNTIME — the library sets
    ``NeedTANResponse.decoupled`` from response code ``3955`` in
    ``_send_with_possible_retry``, not from any HITANS field. There is no
    ``decoupled_parameters`` attribute. So this is only a *selection*
    heuristic: TwoStepParameters7 adds the decoupled polling fields
    (``decoupled_max_poll_number``, ``automated_polling_allowed``), whose
    presence marks a mechanism that CAN run decoupled. The authoritative
    check happens later, on the challenge itself.
    """
    for attr in ("decoupled_max_poll_number", "automated_polling_allowed",
                 "wait_before_first_poll"):
        if getattr(param, attr, None) is not None:
            return True
    return False


def _looks_like_pushtan(param):
    blob = " ".join(str(getattr(param, a, "") or "") for a in
                    ("name", "tech_id", "zka_id")).lower()
    return "push" in blob or "decoupled" in blob


def pick_mechanism(mechs):
    """Choose the pushTAN mechanism. Returns (sec_func, param).

    Preference order: pushTAN-named ∩ decoupled-capable, then pushTAN-named,
    then decoupled-capable. Returns (None, None) if nothing matches, in which
    case the caller lists what the bank offered instead of guessing.
    """
    items = list(mechs.items())
    for pred in (lambda p: _looks_like_pushtan(p) and _supports_decoupled(p),
                 _looks_like_pushtan,
                 _supports_decoupled):
        for sec, param in items:
            if pred(param):
                return sec, param
    return None, None


def do_status():
    info = fc.state_info()
    out(f"state file : {info['state_path']}")
    out(f"enrolled   : {info.get('enrolled')}")
    if info.get("enrolled"):
        out(f"mode       : {info.get('mode')}")
        out(f"enrolled_at: {info.get('enrolled_at')}")
        out(f"mechanism  : {info.get('tan_mechanism')}  medium: {info.get('tan_medium')}")
        out(f"age (days) : {info.get('state_age_days')}")
        out(f"re-auth due: {info.get('reauth_due')} "
            f"({info.get('reauth_days_remaining')} days remaining)")
        if info.get("reauth_expired"):
            out("STATUS     : EXPIRED — re-run this script")
    else:
        out(f"NOTE       : {info.get('message', 'run enroll.py')}")
    return 0


def main(argv):
    if "--status" in argv:
        return do_status()

    try:
        cfg = fc.load_config()
    except fc.SetupError as e:
        out(f"SETUP ERROR: {e.payload['message']}")
        out(f"  {e.payload.get('hint', '')}")
        return 1

    try:
        from fints.client import FinTSClientMode, NeedRetryResponse
    except ImportError as e:
        out(f"ERROR: the `fints` package is not importable ({e}).")
        out("  Run this from the Nix wrapper: "
            "nix-shell -p 'python3.withPackages (ps: [ ps.fints ])'")
        return 1

    out(f"Bank endpoint : {cfg.endpoint}")
    out(f"BLZ           : {cfg.blz}")
    out("Credentials   : from the environment (never echoed)")
    out("")

    # Start FRESH (no from_data): enrollment is exactly the case where we want
    # the bank to assign a new system id under a real SCA approval.
    client = fc.build_client(cfg, mode=FinTSClientMode.INTERACTIVE)

    try:
        # ------------------------------------------------------------------
        # Mechanism + medium selection happens OUTSIDE `with client:`.
        # python-fints raises "Cannot change TAN mechanism/medium with a
        # standing dialog" if either setter is called while a standing dialog
        # is open (verified in 5.0.0: set_tan_mechanism/set_tan_medium both
        # guard on self._standing_dialog). fetch_tan_mechanisms() populates
        # the BPD and allowed_security_functions that get_tan_mechanisms()
        # reads, so it must come first.
        # ------------------------------------------------------------------
        out("Fetching available TAN mechanisms…")
        client.fetch_tan_mechanisms()
        mechs = client.get_tan_mechanisms()
        if not mechs:
            out("ERROR: the bank offered no TAN mechanisms. Check "
                "FINTS_USER_ID (Anmeldename, not the account number).")
            return 1
        for s, p in mechs.items():
            out(f"  [{s}] {_mechanism_name(p)}"
                f"{'  (decoupled-capable)' if _supports_decoupled(p) else ''}")

        sec, param = pick_mechanism(mechs)
        if sec is None:
            out("")
            out("ERROR: no pushTAN/decoupled mechanism among the above.")
            out("  This card targets the S-pushTAN app. If Karl uses a "
                "different method, pick its number manually and re-run.")
            return 1
        out(f"\nSelecting mechanism [{sec}] {_mechanism_name(param)}")
        client.set_tan_mechanism(sec)

        medium_name = None
        if client.is_tan_media_required():
            out("This mechanism requires naming a TAN medium; fetching…")
            # get_tan_media() returns (TANUsageOption, [TANMedia4|5, ...]) —
            # always a 2-tuple in python-fints 5.0.0 (verified).
            _usage, media_list = client.get_tan_media()
            media_list = [m for m in (media_list or [])
                          if getattr(m, "tan_medium_name", None)]
            if not media_list:
                out("ERROR: the bank reported no usable TAN media.")
                return 1
            for m in media_list:
                out(f"  - {m.tan_medium_name}")
            medium = media_list[0]
            medium_name = str(medium.tan_medium_name)
            out(f"Using TAN medium: {medium_name}")
            client.set_tan_medium(medium)

        with client:
            out("\nTriggering a statement read to force the SCA challenge…")
            try:
                rows, iban = fc.fetch_rows(client, days=1)
                out(f"No TAN was demanded (already authorised); read "
                    f"{len(rows)} transaction(s) from …{iban[-4:]}.")
            except fc.TanRequired as e:
                resp = e.response
                out("")
                out("=" * 68)
                out("PUSHTAN APPROVAL REQUIRED")
                challenge = (getattr(resp, "challenge", None) or "").strip()
                if challenge:
                    out(f"  Bank challenge: {challenge}")
                if e.decoupled:
                    out("  Open the S-pushTAN app on your phone and APPROVE "
                        "the request.")
                else:
                    out("  WARNING: the bank returned a NON-decoupled challenge.")
                    out("  This script only automates the decoupled (app-approval) "
                        "flow; abort and re-run once pushTAN is the active method.")
                    return 1
                out("=" * 68)
                out(f"Polling every {POLL_INTERVAL}s (timeout "
                    f"{POLL_TIMEOUT // 60} min). Ctrl-C to abort.")

                deadline = time.time() + POLL_TIMEOUT
                waited = 0
                while True:
                    if time.time() > deadline:
                        out(f"\nTIMEOUT: no approval after {POLL_TIMEOUT}s. "
                            f"Nothing was written; just re-run this script.")
                        return 1
                    time.sleep(POLL_INTERVAL)
                    waited += POLL_INTERVAL
                    # Decoupled: the tan value is IGNORED by the library; a
                    # still-pending approval re-returns a NeedTANResponse
                    # (bank response code 3956).
                    result = client.send_tan(resp, "")
                    if isinstance(result, NeedRetryResponse):
                        out(f"  …still waiting for approval ({waited}s)")
                        resp = result
                        continue
                    out("\nApproved. ✓")
                    break

            out("Persisting FinTS state…")
            blob = client.deconstruct(including_private=True)
            with fc.StateLock():
                p = fc.save_state(blob,
                                  tan_mechanism=f"[{sec}] {_mechanism_name(param)}",
                                  tan_medium=medium_name)
            mode = oct(os.stat(p).st_mode & 0o777)
            out(f"  wrote {p} (mode {mode})")
            if mode != "0o600":
                out(f"  WARNING: expected mode 0o600, got {mode}")
    except KeyboardInterrupt:
        out("\nAborted by user. Nothing was written.")
        return 1
    except fc.SetupError as e:
        out(f"SETUP ERROR: {e.payload['message']}")
        return 1
    except Exception as e:  # noqa: BLE001 — scrub before printing
        out(f"ERROR: {type(e).__name__}: {fc.scrub(e, cfg)}")
        return 1

    # Make sure the DB exists with the seeded taxonomy, so the very first
    # cron sync has somewhere to write.
    path = db.migrate()
    out(f"  database ready at {path} (mode {oct(os.stat(path).st_mode & 0o777)})")

    out("")
    info = fc.state_info()
    out(f"ENROLLED. Re-auth due {info.get('reauth_due')} "
        f"({info.get('reauth_days_remaining')} days). Syncs should now run "
        f"TAN-free until then.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
