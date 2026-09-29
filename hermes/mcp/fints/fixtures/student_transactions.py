#!/usr/bin/env python3
"""46 realistic German student transactions with ground-truth categories.

Hand-written to look like what Sparkasse Nienburg actually puts in MT940: the
purpose line is uppercase-ish, abbreviated, full of booking keys (KARTENZAHLUNG,
SEPA-ELV, DAUERAUFTRAG) and terminal/receipt noise. `expected` is the ground
truth used to score the LLM pass — it is NEVER shown to the model.

Deliberately includes the cases that break naive classifiers:
  * DM and Rossmann (drugstore) — genuinely ambiguous between Lebensmittel and
    Gesundheit, so a disagreement there is informative, not a bug.
  * An Amazon order and a Kleinanzeigen payment with no useful merchant hint.
  * A refund (positive amount at a merchant) — sign handling.
  * An internal savings transfer — the `transfer` kind.
  * A hairdresser, which has no matching category at all and SHOULD trigger a
    new-category proposal rather than a forced wrong label.
"""

# (booking_date, amount_cents, purpose, counterparty_name, counterparty_iban,
#  posting_text, expected_category)
FIXTURES = [
    # --- groceries ---
    ("2026-08-03", -2341, "DANKE, IHR LIDL//NIENBURG/DE 2026-08-03T14:22:41 KFN 1 VJ 2811",
     "LIDL SAGT DANKE", "DE91500105175711234567", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-08-07", -1887, "REWE SAGT DANKE. 2026-08-07T11:03:55 KFN 2 VJ 2811",
     "REWE Markt GmbH", "DE44500105175407324931", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-08-14", -3126, "DANKE, IHR LIDL//NIENBURG/DE 2026-08-14T17:41:09 KFN 1 VJ 2811",
     "LIDL SAGT DANKE", "DE91500105175711234567", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-08-21", -947, "ALDI SAGT DANKE 2026-08-21T09:12:33",
     "ALDI GmbH & Co KG", "DE12500105170648489890", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-09-02", -2705, "REWE SAGT DANKE. 2026-09-02T16:58:12 KFN 2 VJ 2811",
     "REWE Markt GmbH", "DE44500105175407324931", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-09-11", -1654, "EDEKA NIENBURG FIL. 4412 2026-09-11T12:31:00",
     "EDEKA MINDEN-HANNOVER", "DE68500105177316549802", "KARTENZAHLUNG", "Lebensmittel"),
    ("2026-09-18", -2219, "DANKE, IHR LIDL//NIENBURG/DE 2026-09-18T18:02:47 KFN 1 VJ 2811",
     "LIDL SAGT DANKE", "DE91500105175711234567", "KARTENZAHLUNG", "Lebensmittel"),

    # --- mensa / eating out ---
    ("2026-08-05", -420, "SEPA-ELV 58412 STUDENTENWERK MENSA AUFWERTUNG",
     "Studentenwerk OstNiedersachsen", "DE22250500000012345678", "KARTENZAHLUNG",
     "Mensa & Essen unterwegs"),
    ("2026-08-12", -385, "MENSA CAMPUS KARTE AUFWERTUNG AUTOMAT 3",
     "Studentenwerk OstNiedersachsen", "DE22250500000012345678", "KARTENZAHLUNG",
     "Mensa & Essen unterwegs"),
    ("2026-08-19", -1190, "DOENER & MEHR NIENBURG 2026-08-19T20:14:02",
     "Anadolu Imbiss", None, "KARTENZAHLUNG", "Mensa & Essen unterwegs"),
    ("2026-09-04", -560, "BACKWERK BAHNHOF HANNOVER",
     "BackWerk Service GmbH", None, "KARTENZAHLUNG", "Mensa & Essen unterwegs"),
    ("2026-09-09", -420, "SEPA-ELV 58412 STUDENTENWERK MENSA AUFWERTUNG",
     "Studentenwerk OstNiedersachsen", "DE22250500000012345678", "KARTENZAHLUNG",
     "Mensa & Essen unterwegs"),
    ("2026-09-22", -1450, "L OSTERIA HANNOVER 2026-09-22T19:33:51",
     "L Osteria GmbH", None, "KARTENZAHLUNG", "Mensa & Essen unterwegs"),

    # --- university ---
    ("2026-08-15", -37850, "SEMESTERBEITRAG WS 2026/27 MATRIKELNR 7741823",
     "Hochschule Hannover", "DE55250500000098765432", "UEBERWEISUNG",
     "Uni & Studium"),
    ("2026-09-01", -4990, "FACHSCHAFT SKRIPT DRUCKKOSTEN INFORMATIK",
     "Fachschaft Informatik e.V.", "DE19250500000011223344", "UEBERWEISUNG",
     "Uni & Studium"),
    ("2026-09-15", -2899, "THALIA.DE BESTELLUNG FACHBUCH ALGORITHMEN",
     "Thalia Buecher GmbH", "DE37200400000123456789", "SEPA-LASTSCHRIFT",
     "Uni & Studium"),

    # --- transport ---
    ("2026-08-01", -4900, "DEUTSCHLANDTICKET SEMESTER AUFPREIS 08/2026",
     "Deutsche Bahn Vertrieb GmbH", "DE07500700100175526303", "SEPA-LASTSCHRIFT",
     "Transport & Semesterticket"),
    ("2026-08-23", -2870, "DB VERTRIEB GMBH FAHRKARTE HANNOVER-BREMEN",
     "Deutsche Bahn Vertrieb GmbH", "DE07500700100175526303", "SEPA-LASTSCHRIFT",
     "Transport & Semesterticket"),
    ("2026-09-01", -4900, "DEUTSCHLANDTICKET SEMESTER AUFPREIS 09/2026",
     "Deutsche Bahn Vertrieb GmbH", "DE07500700100175526303", "SEPA-LASTSCHRIFT",
     "Transport & Semesterticket"),
    ("2026-09-19", -1520, "FLIXBUS HANNOVER-BERLIN BUCHUNG 88213",
     "Flix SE", "DE29700202700012345678", "KARTENZAHLUNG",
     "Transport & Semesterticket"),

    # --- subscriptions / digital ---
    ("2026-08-04", -1099, "Spotify Premium Family Mitglied 2026-08",
     "Spotify AB", "DE12700202700099887766", "SEPA-LASTSCHRIFT", "Abos & Digital"),
    ("2026-09-04", -1099, "Spotify Premium Family Mitglied 2026-09",
     "Spotify AB", "DE12700202700099887766", "SEPA-LASTSCHRIFT", "Abos & Digital"),
    ("2026-08-16", -799, "NETFLIX.COM ABO STANDARD 2026-08",
     "Netflix International B.V.", "NL55INGB0678912345", "SEPA-LASTSCHRIFT",
     "Abos & Digital"),
    ("2026-09-16", -799, "NETFLIX.COM ABO STANDARD 2026-09",
     "Netflix International B.V.", "NL55INGB0678912345", "SEPA-LASTSCHRIFT",
     "Abos & Digital"),
    ("2026-08-28", -1000, "GITHUB COPILOT SUBSCRIPTION MONTHLY",
     "GitHub Inc.", None, "SEPA-LASTSCHRIFT", "Abos & Digital"),

    # --- phone / internet ---
    ("2026-08-02", -1499, "TELEKOM DEUTSCHLAND GMBH MOBILFUNK RG 08/2026 KD 4471182",
     "Telekom Deutschland GmbH", "DE89500700100175526300", "SEPA-LASTSCHRIFT",
     "Handy & Internet"),
    ("2026-09-02", -1499, "TELEKOM DEUTSCHLAND GMBH MOBILFUNK RG 09/2026 KD 4471182",
     "Telekom Deutschland GmbH", "DE89500700100175526300", "SEPA-LASTSCHRIFT",
     "Handy & Internet"),

    # --- insurance / health ---
    ("2026-08-10", -12520, "TK BEITRAG KV/PV 08/2026 VERS-NR M123456789",
     "Techniker Krankenkasse", "DE16200400000123456700", "SEPA-LASTSCHRIFT",
     "Versicherung & Krankenkasse"),
    ("2026-09-10", -12520, "TK BEITRAG KV/PV 09/2026 VERS-NR M123456789",
     "Techniker Krankenkasse", "DE16200400000123456700", "SEPA-LASTSCHRIFT",
     "Versicherung & Krankenkasse"),
    ("2026-08-27", -1050, "APOTHEKE AM MARKT REZEPTGEBUEHR",
     "Marien-Apotheke Nienburg", None, "KARTENZAHLUNG", "Gesundheit"),

    # --- rent ---
    ("2026-08-01", -39000, "MIETE WG ZIMMER 08/2026 NIENBURG BAHNHOFSTR 14",
     "Hausverwaltung Meyer GbR", "DE33250500000055667788", "DAUERAUFTRAG",
     "Miete & Nebenkosten"),
    ("2026-09-01", -39000, "MIETE WG ZIMMER 09/2026 NIENBURG BAHNHOFSTR 14",
     "Hausverwaltung Meyer GbR", "DE33250500000055667788", "DAUERAUFTRAG",
     "Miete & Nebenkosten"),

    # --- leisure ---
    ("2026-08-09", -2400, "CINEPLEX NIENBURG KINOKARTEN 2",
     "Cineplex Nienburg GmbH", None, "KARTENZAHLUNG", "Freizeit & Ausgehen"),
    ("2026-08-30", -1800, "SPORTVEREIN NIENBURG MITGLIEDSBEITRAG Q3",
     "TSV Nienburg e.V.", "DE47250500000077889900", "SEPA-LASTSCHRIFT",
     "Freizeit & Ausgehen"),
    ("2026-09-13", -3200, "HANS IM GLUECK HANNOVER 2026-09-13T21:44:18",
     "Hans im Glueck Franchise GmbH", None, "KARTENZAHLUNG", "Freizeit & Ausgehen"),

    # --- clothing ---
    ("2026-08-18", -5990, "H&M HENNES MAURITZ HANNOVER FIL 221",
     "H & M Hennes & Mauritz B.V.", None, "KARTENZAHLUNG", "Kleidung"),

    # --- cash ---
    ("2026-08-08", -5000, "BARGELDAUSZAHLUNG GA NR 00012345 NIENBURG 08.08/13.11UHR",
     None, None, "BARGELDAUSZAHLUNG", "Bargeld"),
    ("2026-09-06", -10000, "BARGELDAUSZAHLUNG GA NR 00012345 NIENBURG 06.09/17.22UHR",
     None, None, "BARGELDAUSZAHLUNG", "Bargeld"),

    # --- income ---
    ("2026-08-01", 45000, "UNTERHALT AUGUST 2026 GRUSS PAPA",
     "Thomas Muster", "DE02120300000000202051", "GUTSCHRIFT", "Unterhalt/Allowance"),
    ("2026-09-01", 45000, "UNTERHALT SEPTEMBER 2026 GRUSS PAPA",
     "Thomas Muster", "DE02120300000000202051", "GUTSCHRIFT", "Unterhalt/Allowance"),
    ("2026-08-11", 73200, "BAFOEG FOERDERUNGSBETRAG 08/2026 AZ 4471182",
     "Landeshauptstadt Hannover Amt fuer Ausbildungsfoerderung",
     "DE85250500000000123456", "GUTSCHRIFT", "BAföG"),
    ("2026-09-11", 73200, "BAFOEG FOERDERUNGSBETRAG 09/2026 AZ 4471182",
     "Landeshauptstadt Hannover Amt fuer Ausbildungsfoerderung",
     "DE85250500000000123456", "GUTSCHRIFT", "BAföG"),
    ("2026-08-31", 32000, "LOHN/GEHALT 08/2026 WERKSTUDENT IT-SUPPORT",
     "Nienburger Software GmbH", "DE21250500000044556677", "GUTSCHRIFT", "Nebenjob"),
    ("2026-09-20", 2899, "GUTSCHRIFT RETOURE BESTELLUNG 302-8841923",
     "Amazon EU S.a.r.l.", "DE87300308800012345678", "GUTSCHRIFT", "Rückerstattung"),

    # --- transfer ---
    ("2026-08-25", -10000, "UEBERTRAG AUF TAGESGELDKONTO SPAREN",
     "Karl Muster", "DE55250501800099998888", "UEBERWEISUNG", "Umbuchung/Sparen"),

    # --- ambiguous / proposal-bait ---
    ("2026-09-08", -1876, "DM DROGERIEMARKT SAGT DANKE FIL 1204",
     "DM-drogerie markt GmbH", "DE95500105170123456789", "KARTENZAHLUNG", None),
    ("2026-09-25", -2800, "FRISEUR SALON SCHNITTSTELLE HERRENSCHNITT",
     "Salon Schnittstelle", None, "KARTENZAHLUNG", None),
]


def as_rows(iban="DE12250501800012345678"):
    """Fixture tuples -> db.insert_transactions() row dicts."""
    out = []
    for (bdate, cents, purpose, cpty, cpty_iban, posting, _expected) in FIXTURES:
        out.append({
            "iban": iban,
            "booking_date": bdate,
            "value_date": bdate,
            "amount_cents": cents,
            "currency": "EUR",
            "purpose": purpose,
            "counterparty_name": cpty,
            "counterparty_iban": cpty_iban,
            "posting_text": posting,
            "end_to_end_id": None,
            "raw_json": None,
        })
    return out


def expected_by_key():
    """(booking_date, amount_cents, purpose) -> expected category or None.

    Keyed on the natural fields rather than on row id, because ids are assigned
    by SQLite at insert time.
    """
    return {(b, c, p): exp
            for (b, c, p, _n, _i, _t, exp) in FIXTURES}
