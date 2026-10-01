# hermes/google/capabilities.nix -- the capability table.  SINGLE SOURCE OF TRUTH.
#
# A capability is a short, reviewable NAME for a bundle of Google OAuth scope
# URLs.  `hermes/users/<name>.nix` names capabilities; nothing anywhere names a
# raw scope URL.  That is the whole point: a reviewer reading
#
#     google.accounts.personal.capabilities = [ "mail.read" "mail.labels" ];
#
# can tell what the account may do without decoding six
# `https://www.googleapis.com/auth/...` strings, and a typo is an eval error
# (see ./default.nix) rather than a silently over-broad grant.
#
# WHAT THIS FILE IS NOT: it is not a security boundary.  Google enforces access
# against the scopes baked into the *token* that was minted by a consent screen
# (any call outside them returns `403 insufficient_permission`).  This table
# decides what the auth CLI *asks* for.  A token that was minted earlier, with
# wider scopes, keeps those scopes until it is re-consented -- shrinking a
# capability list here does NOT shrink an existing token.  `hermes-google-status`
# prints declared-vs-granted side by side precisely because they can disagree.
#
# This file is deliberately PLAIN DATA: no `pkgs`, no `lib`, no module
# arguments.  `import ./capabilities.nix` works from anywhere, including a
# non-module consumer (an agenix rules file, a quick `nix eval`), and cannot
# drag NixOS evaluation in behind it.  Keep it that way.
#
# Attribute names are QUOTED ("mail.read", not mail.read) on purpose.  Unquoted
# dots in Nix build a NESTED attrset -- `mail.read = x;` means
# `mail = { read = x; }` -- which would make the capability name `mail`, break
# `builtins.attrNames`, and silently destroy the enum type in ./default.nix.
{
    # ---------------------------------------------------------------- Gmail --
    #
    # The Gmail scope ladder, verified against the live Gmail v1 discovery
    # document (`https://gmail.googleapis.com/$discovery/rest?version=v1`), not
    # from documentation prose.  Each entry says what it enables AND what it
    # also implies, because the implications are where the surprises are.

    # Read messages and threads, list labels, read (but not write) filters.
    # Grants NO mutation of any kind and no send.
    "mail.read" = [ "https://www.googleapis.com/auth/gmail.readonly" ];

    # Create / rename / delete LABELS (`users.labels.create|update|delete`).
    # Does NOT grant applying a label to a message -- that is `messages.modify`,
    # i.e. "mail.write" below.  Does NOT grant send.
    "mail.labels" = [ "https://www.googleapis.com/auth/gmail.labels" ];

    # Create / delete FILTERS (`users.settings.filters.create|delete`), i.e.
    # server-side labeling RULES, plus the rest of `settings.basic`
    # (vacation responder, IMAP/POP settings, language).  Does NOT grant send.
    #
    # A filter is the interesting capability for "auto-label my mail": Google
    # applies it at delivery time, so it keeps working while the agent is
    # offline, and it needs no per-message write access.
    "mail.rules" = [ "https://www.googleapis.com/auth/gmail.settings.basic" ];

    # ########################################################################
    # # /!\ WARNING: "mail.write" ALSO GRANTS SEND.  THIS IS NOT OPTIONAL.    #
    # #                                                                      #
    # # gmail.modify is the only scope that permits `users.messages.modify`   #
    # # and `batchModify` (apply/remove a label on an EXISTING message) and   #
    # # `trash`/`untrash`.  It is ALSO on the accepted-scope list for         #
    # # `users.messages.send`.                                               #
    # #                                                                      #
    # # Computed from the discovery document: the set of Gmail scopes that     #
    # # allow messages.modify but NOT messages.send is EMPTY.  There is no    #
    # # narrower scope, no combination, and no workaround -- Google couples   #
    # # them.  Granting an agent the ability to re-label mail it has already  #
    # # received therefore necessarily grants it the ability to send mail as  #
    # # that account.                                                        #
    # #                                                                      #
    # # If you want auto-labeling WITHOUT send, use "mail.rules" (a Gmail     #
    # # filter) and accept that it only applies to mail arriving from now on. #
    # # Backfilling labels onto existing mail requires this capability and    #
    # # therefore requires accepting send.                                   #
    # ########################################################################
    "mail.write" = [ "https://www.googleapis.com/auth/gmail.modify" ];

    # Send mail only.  Cannot read, cannot label, cannot delete.  Useful for a
    # notification-only account.
    "mail.send" = [ "https://www.googleapis.com/auth/gmail.send" ];

    # The historical bundle: everything the vendored google-workspace skill's
    # setup.py requested for Gmail -- gmail.readonly, gmail.send AND
    # gmail.modify, in that exact set.  Kept as a named capability so the
    # deprecated `googleWorkspace.enable = true` alias has something exact to
    # resolve to, and so a migrated account's token stays valid with no
    # re-consent.
    #
    # gmail.readonly is redundant on its own (gmail.modify already grants read)
    # and is listed anyway, deliberately: the EXISTING token on this host has
    # all three in its `scopes` array, the vendored google_api.py compares a
    # token's stored scopes against its own SCOPES list, and dropping one would
    # make a perfectly good token look incomplete.  Byte-equality with the
    # historical set is the whole value of this entry.
    #
    # Prefer the narrow capabilities above for anything new.  Inherits the /!\
    # above in full: it contains gmail.modify.
    "mail.full" = [
        "https://www.googleapis.com/auth/gmail.readonly"
        "https://www.googleapis.com/auth/gmail.modify"
        "https://www.googleapis.com/auth/gmail.send"
    ];

    # Permanent, unrecoverable deletion (`users.messages.delete`), plus
    # everything else Gmail can do.  The mail.google.com scope is Gmail's
    # all-powerful scope; nothing in this repo should use it.  Listed so that
    # "why is there no delete capability" has an answer in the table rather
    # than in someone's memory.
    #
    # "mail.destroy" = [ "https://mail.google.com/" ];

    # ------------------------------------------------------------- Calendar --

    # Read AND write events on every calendar the account can see.  Google
    # offers calendar.readonly and calendar.events as narrower scopes; add them
    # as `calendar.ro` / `calendar.events` here when something actually needs
    # the distinction, rather than pre-emptively.
    "calendar.rw" = [ "https://www.googleapis.com/auth/calendar" ];

    # Read-only view of calendars and events.  No creation, no edits.
    "calendar.ro" = [ "https://www.googleapis.com/auth/calendar.readonly" ];

    # ---------------------------------------------------------------- Drive --

    # /!\ Full Drive: read, write and DELETE every file in the account's Drive.
    # Google classes this as a restricted scope.  `drive.file` (per-file access
    # granted by a picker) is far narrower but cannot be driven headlessly, so
    # it is not offered here.
    "drive.rw" = [ "https://www.googleapis.com/auth/drive" ];

    # Metadata and content read, no writes.
    "drive.ro" = [ "https://www.googleapis.com/auth/drive.readonly" ];

    # ------------------------------------------------- Sheets / Docs / etc. --

    # Read and write spreadsheet CELLS of sheets the account can open.  Does
    # NOT grant finding them -- discovery is Drive's job, so a workflow that
    # searches for a sheet by name needs drive.ro or drive.rw too.
    "sheets.rw" = [ "https://www.googleapis.com/auth/spreadsheets" ];
    "sheets.ro" = [ "https://www.googleapis.com/auth/spreadsheets.readonly" ];

    # Read and write Google Docs document content.  Same discovery caveat as
    # sheets.rw.
    "docs.rw" = [ "https://www.googleapis.com/auth/documents" ];
    "docs.ro" = [ "https://www.googleapis.com/auth/documents.readonly" ];

    # Read the account's own contacts.  There is no write capability here on
    # purpose: nothing in this fleet writes contacts, and `contacts` (rw) would
    # let an agent silently rewrite the address book it also reads when
    # deciding who to mail.
    "contacts.ro" = [ "https://www.googleapis.com/auth/contacts.readonly" ];
}
