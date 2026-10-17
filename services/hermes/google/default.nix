{ lib, ... }:

let
    capabilities = import ./capabilities.nix;

    names = builtins.attrNames capabilities;

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

    capabilityNames = builtins.sort (a: b: a < b) names;
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

    reference = {
        inherit capabilityNames;
        scopes = capabilities;
        sendCapabilities = builtins.filter grantsSend capabilityNames;
        remediation = remediationFor;
    };
}
