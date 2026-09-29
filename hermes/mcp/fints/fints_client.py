#!/usr/bin/env python3
"""Shared FinTS layer: env config, client construction, state file, MT940 mapping.

READ-ONLY BY CONSTRUCTION. The only FinTS operations this module can perform
are ``get_sepa_accounts()`` and ``get_transactions()``. No SEPA transfer, no
standing order, no HKCCS/HKDSE segment is referenced anywhere in this package —
that is a property of the code, not a runtime flag, and test_harness.py asserts
it by scanning the module surface (section 5).

PIN handling
------------
The PIN is read from the env, handed straight to ``FinTS3PinTanClient`` and
never stored, logged, or returned:
  * ``log()`` writes to stderr only and every call site passes a literal —
    no value derived from the config is ever formatted into a log line.
  * python-fints wraps the PIN in ``fints.formals.Password``, whose ``__str__``
    yields ``'***'`` inside a ``Password.protect()`` block. The library already
    wraps its own wire-trace logging in that block, and ``scrub()`` below is
    applied to every exception message we surface, so a PIN cannot reach a
    tool response even if a library traceback embedded it.
  * ``deconstruct()`` is documented by python-fints as containing neither
    connection info nor the PIN; the state file therefore holds no credential,
    but it is still written 0600 (it does hold account numbers/names).

Verified against python-fints 5.0.0 in this nixpkgs (2026-09-29):
  * ``FinTS3Client.__init__`` raises ``TypeError`` when ``product_id`` is
    falsy — there is no library default, hence ``FINTS_PRODUCT_ID`` is
    mandatory and its absence is reported as a structured setup error.
  * ``fints.utils.mt940_to_array`` returns a plain ``list`` of
    ``mt940.models.Transaction``; the ``.data`` keys used below
    (``amount``/``date``/``entry_date``/``purpose``/``applicant_name``/
    ``applicant_iban``/``posting_text``/``end_to_end_reference``) were
    ground-truthed against a real MT940 fixture.
  * ``amount`` is an ``mt940.models.Amount`` carrying a signed
    ``decimal.Decimal`` (D -> negative, C -> positive), so the Soll/Haben sign
    comes from the library and cents are computed with Decimal, never float.
"""
import base64
import fcntl
import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

# PSD2 strong-customer-authentication re-auth window. Sparkasse Nienburg's own
# security page states 180 days (NOT the commonly-cited 90).
SCA_VALIDITY_DAYS = 180

DEFAULT_STATE = "~/.hermes/finance/fints_state.json"

# Env var names, in one place (the nixos card owns the other half of this
# contract: rendering them into the agenix-encrypted .env).
ENV_BLZ = "FINTS_BLZ"
ENV_ENDPOINT = "FINTS_ENDPOINT"
ENV_USER_ID = "FINTS_USER_ID"
ENV_PIN = "FINTS_PIN"
ENV_PRODUCT_ID = "FINTS_PRODUCT_ID"
ENV_STATE = "FINTS_STATE"

REQUIRED_ENV = (ENV_BLZ, ENV_ENDPOINT, ENV_USER_ID, ENV_PIN, ENV_PRODUCT_ID)


def log(*a):
    """stderr only. Never called with a credential-derived value."""
    print(*a, file=sys.stderr, flush=True)


def state_path():
    return os.path.expanduser(os.environ.get(ENV_STATE) or DEFAULT_STATE)


# ---------- structured errors (never raised across the MCP boundary) ----------
def err(code, message, **extra):
    d = {"ok": False, "error": code, "message": message}
    d.update(extra)
    return d


class SetupError(Exception):
    """Missing/invalid configuration. Carries a structured payload."""

    def __init__(self, payload):
        super().__init__(payload.get("message", "setup error"))
        self.payload = payload


class TanRequired(Exception):
    """The bank demanded a (push)TAN we cannot satisfy non-interactively.

    python-fints signals this by RETURNING a ``NeedTANResponse`` (it is not an
    exception subclass — verified against 5.0.0), which is awkward to
    propagate through a call chain. This wrapper makes the demand catchable
    exactly once, at the MCP tool boundary, where it becomes the structured
    ``{"ok": false, "error": "tan_required", ...}`` result.
    """

    def __init__(self, response=None):
        super().__init__("TAN required")
        self.response = response

    @property
    def challenge(self):
        return getattr(self.response, "challenge", None) or ""

    @property
    def decoupled(self):
        return bool(getattr(self.response, "decoupled", False))


# ---------- config ----------
class Config:
    """FinTS connection parameters from the environment.

    ``pin`` is held as a plain attribute for the single purpose of passing it
    to the client constructor. ``__repr__`` is overridden so an accidental
    repr() in a log line or traceback cannot leak it.
    """

    __slots__ = ("blz", "endpoint", "user_id", "pin", "product_id")

    def __init__(self, blz, endpoint, user_id, pin, product_id):
        self.blz = blz
        self.endpoint = endpoint
        self.user_id = user_id
        self.pin = pin
        self.product_id = product_id

    def __repr__(self):
        return (f"Config(blz={self.blz!r}, endpoint={self.endpoint!r}, "
                f"user_id=<redacted>, pin=<redacted>, "
                f"product_id=<redacted>)")

    __str__ = __repr__


def load_config(environ=None):
    """Read + validate the env contract. Raises SetupError with a payload."""
    e = environ if environ is not None else os.environ
    missing = [k for k in REQUIRED_ENV if not (e.get(k) or "").strip()]
    if missing:
        hint = (f"Set {', '.join(missing)} in the agenix-encrypted "
                f"~/.hermes/.env (the nixos card owns that wiring).")
        if ENV_PRODUCT_ID in missing:
            # python-fints >= 4 has NO built-in product id: product_id is a
            # mandatory kwarg and raises TypeError if absent, so "use the
            # library default" is not an option. Verified in 5.0.0.
            hint += (f" {ENV_PRODUCT_ID} has no default: python-fints >= 4 "
                     f"requires a FinTS Produkt-ID (register at fints.org, or "
                     f"try a placeholder first — see README).")
        raise SetupError(err("setup_incomplete",
                             f"missing required env var(s): {', '.join(missing)}",
                             missing=missing, hint=hint))
    return Config(blz=e[ENV_BLZ].strip(), endpoint=e[ENV_ENDPOINT].strip(),
                  user_id=e[ENV_USER_ID].strip(), pin=e[ENV_PIN],
                  product_id=e[ENV_PRODUCT_ID].strip())


def scrub(text, cfg=None):
    """Remove the PIN (and user id) from any string before it leaves the process.

    Defence in depth: nothing we write should contain them in the first place,
    but a python-fints traceback or a bank error echo is not under our control.
    Applied to every exception message surfaced by a tool.
    """
    s = str(text)
    secrets = []
    if cfg is not None:
        secrets = [str(cfg.pin), cfg.user_id]
    else:
        secrets = [os.environ.get(ENV_PIN, ""), os.environ.get(ENV_USER_ID, "")]
    for sec in secrets:
        # Guard against a 1-2 char value turning the message into confetti.
        if sec and len(sec) >= 3:
            s = s.replace(sec, "***")
    return s


# ---------- state file (0600, flock-guarded) ----------
class StateLock:
    """Advisory flock on a sidecar file, serialising state read-modify-write.

    Same shape as the OneDrive server's ``_TokenLock``: NON-BLOCKING acquire
    with a bounded retry, and a deliberate fall-through-without-lock so a
    stuck sibling can never deadlock an MCP request. The lock only orders
    writers; a reader that loses the race simply sees the previous valid file
    (the write itself is atomic via os.replace).
    """

    ATTEMPTS = 3
    SLEEP = 1.0

    def __init__(self, path=None):
        self._path = (path or state_path()) + ".lock"
        self._fd = None
        self.held = False

    def acquire(self):
        import time
        d = os.path.dirname(os.path.abspath(self._path))
        try:
            os.makedirs(d, mode=0o700, exist_ok=True)
        except OSError:
            return False
        for _ in range(self.ATTEMPTS):
            try:
                fd = os.open(self._path, os.O_RDWR | os.O_CREAT, 0o600)
            except OSError:
                return False
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)
                time.sleep(self.SLEEP)
                continue
            self._fd = fd
            self.held = True
            return True
        return False

    def release(self):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None
        self.held = False

    def __enter__(self):
        self.acquire()  # best effort, never raises
        return self

    def __exit__(self, *exc):
        self.release()
        return False


def save_state(blob, path=None, enrolled_at=None, tan_mechanism=None,
               tan_medium=None):
    """Persist ``client.deconstruct(including_private=True)`` at 0600.

    The blob is opaque compressed bytes; base64 keeps the file plain JSON so
    ``fints_status`` can read the metadata without the fints package.
    Written to a temp file at 0600 then os.replace()'d — a reader never sees
    a partial file, and the mode is never briefly 0644.
    """
    p = path or state_path()
    doc = {
        "version": 1,
        "enrolled_at": enrolled_at or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sca_validity_days": SCA_VALIDITY_DAYS,
        "tan_mechanism": tan_mechanism,
        "tan_medium": tan_medium,
        # No PIN and no connection info: python-fints documents deconstruct()
        # as excluding both. Account numbers/names ARE included, hence 0600.
        "data_b64": base64.b64encode(bytes(blob)).decode("ascii"),
    }
    d = os.path.dirname(os.path.abspath(p))
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(doc, f, indent=2)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)
    return p


def load_state(path=None):
    """Return (doc, blob_bytes) or (None, None) when not enrolled."""
    p = path or state_path()
    try:
        with open(p) as f:
            doc = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None, None
    b64 = doc.get("data_b64")
    if not b64:
        return doc, None
    try:
        return doc, base64.b64decode(b64)
    except Exception:  # noqa: BLE001 — a corrupt state file is "not enrolled"
        return doc, None


def state_info(path=None):
    """Enrollment metadata WITHOUT contacting the bank (fints_status uses this)."""
    p = path or state_path()
    doc, blob = load_state(p)
    if doc is None:
        return {"enrolled": False, "state_path": p,
                "message": "not enrolled — run enroll.py once"}
    info = {"enrolled": blob is not None, "state_path": p,
            "tan_mechanism": doc.get("tan_mechanism"),
            "tan_medium": doc.get("tan_medium"),
            "enrolled_at": doc.get("enrolled_at")}
    try:
        info["mode"] = oct(os.stat(p).st_mode & 0o777)
    except OSError:
        info["mode"] = None
    days = doc.get("sca_validity_days", SCA_VALIDITY_DAYS)
    try:
        enrolled = datetime.fromisoformat(doc["enrolled_at"])
        if enrolled.tzinfo is None:
            enrolled = enrolled.replace(tzinfo=timezone.utc)
        age = datetime.now(timezone.utc) - enrolled
        info["state_age_days"] = round(age.total_seconds() / 86400, 2)
        info["reauth_days_remaining"] = round(days - age.total_seconds() / 86400, 2)
        info["reauth_due"] = (enrolled + timedelta(days=days)).date().isoformat()
        info["reauth_expired"] = info["reauth_days_remaining"] <= 0
    except (KeyError, TypeError, ValueError):
        info["state_age_days"] = None
        info["reauth_days_remaining"] = None
        info["reauth_due"] = None
        info["reauth_expired"] = None
    return info


# ---------- MT940 -> row mapping (stdlib only; takes a plain dict) ----------
CENT = Decimal("0.01")


def to_cents(amount):
    """Signed cents from a Decimal/str/int. Decimal only — never float.

    The sign comes from MT940's D/C funds code as decoded by the mt940
    library (D -> negative Decimal, C -> positive), so Soll/Haben handling is
    not re-derived here.
    """
    if amount is None:
        return 0
    if isinstance(amount, float):
        # Defensive: a float would already have lost precision. Go via str.
        amount = Decimal(str(amount))
    elif not isinstance(amount, Decimal):
        amount = Decimal(str(amount))
    return int((amount * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _iso(d):
    if d is None:
        return None
    if isinstance(d, str):
        return d
    # mt940.models.Date subclasses datetime.date.
    if isinstance(d, (date, datetime)):
        return d.isoformat()[:10]
    return str(d)


def map_transaction(data, iban=None, fetched_at=None):
    """Map one mt940 transaction ``.data`` dict to a transactions row dict.

    ``data`` is duck-typed (a plain dict), so this is testable with a literal
    fixture and needs neither the bank nor the fints package.
    """
    amt = data.get("amount")
    # mt940.models.Amount carries .amount (Decimal) + .currency.
    raw_amount = getattr(amt, "amount", amt)
    currency = getattr(amt, "currency", None) or data.get("currency")
    booking = _iso(data.get("entry_date") or data.get("date"))
    value = _iso(data.get("date"))
    purpose = data.get("purpose")
    extra = data.get("additional_purpose")
    if extra:
        purpose = f"{purpose or ''}{extra}"
    cents = to_cents(raw_amount)
    row = {
        "iban": iban or data.get("account_identification"),
        "booking_date": booking,
        "value_date": value,
        "amount_cents": cents,
        "currency": currency,
        "purpose": purpose,
        "counterparty_name": data.get("applicant_name"),
        "counterparty_iban": (data.get("applicant_iban")
                              or data.get("gvc_applicant_iban")),
        "posting_text": data.get("posting_text"),
        "end_to_end_id": data.get("end_to_end_reference"),
        "fetched_at": fetched_at,
    }
    # raw_json keeps the full parsed record for reprocessing by the labeling
    # card without a re-fetch. Values are stringified because Decimal/Date are
    # not JSON-serialisable; `default=str` would silently vary by type.
    row["raw_json"] = json.dumps(
        {k: (str(v) if v is not None else None) for k, v in sorted(data.items())},
        ensure_ascii=False)
    return row


def rows_from_mt940(mt940_text, iban=None, fetched_at=None):
    """Parse a raw MT940 string into row dicts (needs the fints package)."""
    from fints.utils import mt940_to_array
    return [map_transaction(t.data, iban=iban, fetched_at=fetched_at)
            for t in mt940_to_array(mt940_text)]


# ---------- client construction (READ-ONLY operations only) ----------
def build_client(cfg, from_data=None, mode=None):
    """Construct a FinTS3PinTanClient. Import is local so db/mapping tests
    (and a bare `python3 mcp_server.py` on a host without the package) do not
    require the fints dependency to be importable."""
    from fints.client import FinTS3PinTanClient, FinTSClientMode
    kwargs = {}
    if from_data is not None:
        kwargs["from_data"] = from_data
    if mode is not None:
        kwargs["mode"] = mode
    else:
        kwargs["mode"] = FinTSClientMode.INTERACTIVE
    return FinTS3PinTanClient(
        bank_identifier=cfg.blz,
        user_id=cfg.user_id,
        pin=cfg.pin,
        server=cfg.endpoint,
        product_id=cfg.product_id,
        **kwargs)


def pick_giro(accounts):
    """Girokonto only: this profile has exactly one SEPA account in scope.

    If the bank returns several, prefer the first whose subaccount is empty
    (a Girokonto is the base account; savings/sub-accounts carry a
    subaccount number), else the first account.
    """
    if not accounts:
        return None
    for a in accounts:
        if not getattr(a, "subaccount", None):
            return a
    return accounts[0]


def fetch_rows(client, days=90, fetched_at=None):
    """READ ONLY: get_sepa_accounts + get_transactions -> (rows, iban).

    A pushTAN demand surfaces as a ``NeedTANResponse`` **return value**, never
    as an exception (verified in python-fints 5.0.0: every construction site
    in fints/client.py is a `return NeedTANResponse(...)`, and the class does
    NOT subclass BaseException — `except NeedTANResponse` would be a TypeError
    at runtime). So both calls are checked with isinstance and the demand is
    propagated as ``TanRequired``, which IS an exception and can be caught.
    """
    from fints.client import NeedRetryResponse

    accounts = client.get_sepa_accounts()
    if isinstance(accounts, NeedRetryResponse):
        raise TanRequired(accounts)
    acct = pick_giro(accounts)
    if acct is None:
        raise SetupError(err("no_account",
                             "the bank returned no SEPA account for this login"))
    end = date.today()
    start = end - timedelta(days=int(days))
    txns = client.get_transactions(acct, start_date=start, end_date=end)
    if isinstance(txns, NeedRetryResponse):
        raise TanRequired(txns)
    ts = fetched_at or datetime.now(timezone.utc).isoformat(timespec="seconds")
    rows = [map_transaction(t.data, iban=acct.iban, fetched_at=ts) for t in txns]
    return rows, acct.iban
