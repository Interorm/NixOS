# hermes/google/default.nix -- capability resolution and validation.
#
# Turns the plain data in ./capabilities.nix into the three things the NixOS
# module actually needs:
#
#   capabilityType   a `lib.types.enum` so an unknown capability name is an
#                    EVAL ERROR that names the valid set, produced by the type
#                    system rather than by a hand-written assertion.
#   scopesFor        [ capability ] -> deduplicated, sorted [ scope-url ]
#   remediationFor   "this account cannot do X; the capability that would
#                    grant it is Y, and here is what Y also implies"
#
# DERIVED, NOT DUPLICATED: every scope URL in this repo comes from
# ./capabilities.nix.  Nothing here, in hermes.nix, in a wrapper, or in the
# generated manifest restates one.  Add a capability to that file and it is
# immediately a legal value of `google.accounts.<n>.capabilities`, appears in
# the eval-error message for a typo, and flows into the wrappers and the
# manifest with no second edit.
#
# Takes only `lib`.  No `pkgs`, no `config`, no module arguments -- so this is
# importable from any context (a plain `nix eval`, an agenix rules file) and
# cannot drag NixOS evaluation in behind it.  The derivations that need `pkgs`
# live in ./wrappers.nix, which is a separate import for exactly that reason.
{ lib, ... }:

let
    capabilities = import ./capabilities.nix;

    names = builtins.attrNames capabilities;

    # Capabilities whose scope set permits sending mail as the account.
    # Derived by asking the table, so adding a send-capable capability above
    # updates every error message that mentions sending.  `gmail.modify` is in
    # here because Google couples modify and send -- see the /!\ block in
    # ./capabilities.nix; that coupling is a fact about Gmail, so it is encoded
    # once, here, next to the only place it is consumed.
    sendScopes = [
        "https://www.googleapis.com/auth/gmail.send"
        "https://www.googleapis.com/auth/gmail.compose"
        "https://www.googleapis.com/auth/gmail.modify"
        "https://mail.google.com/"
    ];

    grantsSend = cap:
        builtins.any (s: builtins.elem s sendScopes) capabilities.${cap};
in
rec {
    inherit capabilities;

    # The valid capability names, sorted.  Printed in error messages and in
    # `hermes-google-status`, so a human never has to open this file to find
    # out what they may write.
    capabilityNames = builtins.sort (a: b: a < b) names;

    # The option type for `google.accounts.<n>.capabilities`.
    #
    # `enum` is the point of this whole file: a typo'd capability fails at EVAL
    # with the valid set in the message, from the type checker --
    #
    #   error: value "mail.readonly" is not one of
    #     "calendar.ro", "calendar.rw", "contacts.ro", ... "mail.read", ...
    #
    # rather than resolving to `capabilities.mail-raedonly` = null and
    # producing an account with an empty scope list that fails only at the
    # consent screen, hours later, in a browser.
    capabilityType = lib.types.listOf (lib.types.enum capabilityNames);

    # [ capability ] -> sorted, deduplicated [ scope-url ].
    #
    # Sorted so the value is stable: an account's derived `scopes` must not
    # change (and so must not change the wrapper's store path, nor the
    # manifest's bytes) merely because somebody reordered the capability list
    # in a user file.  Deduplicated because overlapping bundles are normal --
    # [ "mail.write" "mail.full" ] names gmail.modify twice, and a repeated
    # scope in a consent URL is at best noise and at worst an error.
    scopesFor = caps:
        builtins.sort (a: b: a < b)
            (lib.unique (lib.concatMap (c: capabilities.${c}) caps));

    inherit grantsSend;

    # Capabilities that would grant `verb`, as a human sentence, for the
    # `403 insufficient_permission` translation in the wrappers.  The wrapper
    # knows what the account declared; this says what it would have to declare
    # instead, and what that would cost.
    remediationFor = {
        send = {
            needs = [ "mail.send" "mail.write" "mail.full" ];
            note = "'mail.write' and 'mail.full' ALSO grant send+trash -- Gmail couples modify and send, there is no narrower scope.";
        };
        label = {
            needs = [ "mail.write" "mail.full" ];
            note = "applying a label to an EXISTING message needs gmail.modify, which ALSO grants send. 'mail.rules' (a Gmail filter) labels future mail with no send.";
        };
        "label-manage" = {
            needs = [ "mail.labels" "mail.write" "mail.full" ];
            note = "'mail.labels' creates/renames/deletes label definitions and does NOT grant send.";
        };
        rules = {
            needs = [ "mail.rules" ];
            note = "'mail.rules' (gmail.settings.basic) creates server-side filters and does NOT grant send.";
        };
        read = {
            needs = [ "mail.read" "mail.write" "mail.full" ];
            note = "'mail.read' is read-only and grants nothing else.";
        };
    };

    # Everything a wrapper or the manifest needs to explain itself, as plain
    # JSON-able data.  Bundled here so ./wrappers.nix never reaches into the
    # capability table directly -- one consumer, one interface.
    reference = {
        inherit capabilityNames;
        scopes = capabilities;
        sendCapabilities = builtins.filter grantsSend capabilityNames;
        remediation = remediationFor;
    };
}
