# hermes/google/wrappers.nix -- the generated per-agent Google CLIs.
#
# This is the half of hermes/google/ that needs `pkgs`, kept separate from
# ./default.nix so that the capability table and its resolution stay plain,
# lazily-importable data (see the header comments there).
#
# Called once per agent that declares `google.accounts`, from
# modules/services/hermes/hermes.nix.  Returns:
#
#   { manifest        # store path, the JSON facts (no secrets)
#     packages        # [ derivation ]  -> straight into the agent's extraPackages
#     skillsDir       # store path  -> settings.skills.external_dirs
#   }
#
# WHAT IS BAKED IN AND WHY:  every wrapper has the manifest's store path, the
# interpreter, and the python script's store path interpolated into it by Nix.
# Nothing is read from the environment.  That is deliberate and it is the only
# reason a generated wrapper is worth more than a shell alias: the AGENT RUNS
# THESE COMMANDS, and an agent that could pass `--scope` or point
# HERMES_GOOGLE_MANIFEST at a file it wrote itself could widen its own grant.
# A rebuild is the only way to change the policy, and a rebuild is a reviewed
# git commit.  See ./WRITING-WRAPPERS.md section 5.
#
# (That is a correctness and clarity property, not a hard security boundary --
# the real boundary is the scopes inside the minted token, which Google checks
# on every call.  An agent with shell access can always invoke python directly.
# What baking buys is that the SUPPORTED path cannot drift from the config.)
{ pkgs, lib, agent, accounts, clientSecretFile, hermesHome, googlePython }:

let
    google = import ./default.nix { inherit lib; };

    # ---------------------------------------------------------------------- #
    # The manifest.  `builtins.toJSON` + `writeText` -> a store path the script
    # reads, instead of a heredoc inside a shell script (which would make the
    # data unreadable, unparseable and impossible to diff).  See
    # ./WRITING-WRAPPERS.md section 6.
    #
    # NO SECRETS: paths only.  `clientSecretFile` is /run/agenix/google-<agent>,
    # a path to a file that exists only at runtime on tmpfs; the token paths are
    # likewise paths, not contents.  This file lands in the world-readable Nix
    # store, so that distinction is load-bearing -- consume a secret by `.path`,
    # never by value.
    # ---------------------------------------------------------------------- #
    manifestData = {
        inherit agent clientSecretFile hermesHome;

        # Desktop-app ("installed") OAuth clients may redirect to any loopback
        # address.  Port 1 is chosen precisely BECAUSE nothing can listen there
        # (it is privileged and unused): the browser's "connection refused"
        # page is the signal that the flow worked, and the code is in the URL
        # bar. The alternative -- a real local server -- needs a listening
        # socket in the agent's session, which a headless gateway does not have.
        redirectUri = "http://localhost:1";

        # The capability table itself travels with the manifest, so the CLI's
        # error messages are derived from the same data Nix validated against
        # and cannot drift from it.
        reference = google.reference;

        accounts = lib.mapAttrs (name: acct: {
            inherit (acct) capabilities address purpose publishing project;
            scopes = google.scopesFor acct.capabilities;
            tokenHome = "${hermesHome}/google/${name}";
            # google_api.py hardcodes HERMES_HOME/"google_token.json"; the
            # per-account HERMES_HOME is what makes that per-account.
            tokenPath = "${hermesHome}/google/${name}/google_token.json";
            grantsSend = builtins.any google.grantsSend acct.capabilities;
        }) accounts;
    };

    manifest = pkgs.writeText "hermes-google-accounts-${agent}.json"
        (builtins.toJSON manifestData);

    # The python entry point, copied into the store content-addressed.  NOT a
    # path into the flake checkout: the checkout is mutable on `git pull`, so a
    # runtime reference to it is not reproducible.  copyPathToStore re-derives
    # byte-for-byte from the flake's git revision on every rebuild.
    # ./WRITING-WRAPPERS.md section 7.
    script = pkgs.copyPathToStore ./google_accounts.py;

    # One place that spells out "run OUR script under the interpreter that
    # carries the google API client libraries, with the manifest bound".
    #
    # `googlePython` comes from hermes.nix (python3 + google-auth,
    # google-auth-oauthlib, google-api-python-client).  It is passed in rather
    # than rebuilt here so the auth CLI and the vendored google_api.py can never
    # run under different interpreters -- the exact trap that makes the
    # vendored setup.py unusable on NixOS.
    runner = verb: ''
        export HERMES_GOOGLE_MANIFEST=${manifest}
        exec ${googlePython}/bin/python3 ${script} ${verb} "$@"
    '';

    # `writeShellApplication` over `writeShellScriptBin`: it runs shellcheck as
    # part of the build (so a quoting bug fails the rebuild instead of
    # surfacing at 3am) and takes `runtimeInputs`, which closes over the
    # dependencies instead of trusting the caller's PATH.  These wrappers need
    # no external binaries at all -- everything is inside googlePython -- so
    # runtimeInputs is empty, stated explicitly rather than omitted.
    # ./WRITING-WRAPPERS.md sections 1-2.
    mkWrapper = name: { verb, description }: pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [ ];
        meta.description = description;
        text = ''
            # Generated by hermes/google/wrappers.nix for agent '${agent}'.
            # Do not edit: a nixos-rebuild overwrites it. Change
            # hermes/users/${agent}.nix instead.
            ${runner verb}
        '';
    };

    authWrapper = mkWrapper "hermes-google-auth" {
        verb = "auth";
        description = "One-time Google OAuth consent for a declared account";
    };

    statusWrapper = mkWrapper "hermes-google-status" {
        verb = "status";
        description = "Declared vs granted Google access for every declared account";
    };

    # `--account <name>` in front of whatever google_api.py would take.
    #
    # `"$@"` is quoted so an argument with spaces (a Gmail search query:
    # `hermes-gmail --account personal search "from:bank is:unread"`) survives
    # as ONE argument. Unquoted `$@` would word-split it into three and the
    # search would silently match the wrong thing.
    gmailWrapper = pkgs.writeShellApplication {
        name = "hermes-gmail";
        runtimeInputs = [ ];
        meta.description = "Gmail (and the rest of google_api.py) for a declared account";
        text = ''
            # Generated by hermes/google/wrappers.nix for agent '${agent}'.
            if [ "''${1:-}" != "--account" ] || [ "$#" -lt 2 ]; then
                echo "usage: hermes-gmail --account <name> <service> <subcommand> [args...]" >&2
                echo "  e.g. hermes-gmail --account agent gmail search 'is:unread' --max 5" >&2
                echo "  declared accounts: ${lib.concatStringsSep " " (lib.attrNames accounts)}" >&2
                echo "  see 'hermes-google-status' for what each one may do" >&2
                exit 2
            fi
            account="$2"
            shift 2
            export HERMES_GOOGLE_MANIFEST=${manifest}
            exec ${googlePython}/bin/python3 ${script} api "$account" "$@"
        '';
    };

    # ---------------------------------------------------------------------- #
    # One wrapper PER ACCOUNT, generated from the attrset.
    #
    # `lib.mapAttrsToList` over `accounts`: declaring a new account in
    # hermes/users/<agent>.nix makes `hermes-google-<name>` exist with no second
    # edit anywhere.  That is the "derive, never duplicate" rule applied to
    # executables, and it is what the perturbation test in the PR exercises.
    # ./WRITING-WRAPPERS.md section 8.
    #
    # The account name is baked in, NOT taken as an argument, so the agent
    # cannot aim `hermes-google-personal` at the agent mailbox by mistake.
    # ---------------------------------------------------------------------- #
    perAccountWrappers = lib.mapAttrsToList (name: acct:
        let
            # The account's usage text as its OWN store path, printed with
            # `cat`, instead of one generated `echo` per line.
            #
            # This is not cosmetic.  `purpose` is free prose Karl writes, and it
            # routinely contains backticks and quotes -- which, emitted as shell
            # `echo` arguments, make `writeShellApplication`'s shellcheck gate
            # fail the BUILD (SC2016: "expressions don't expand in single
            # quotes").  Correctly escaping arbitrary prose into shell literals
            # is a losing game; taking the data out of the script entirely wins
            # it.  Disabling the warning would have been the wrong fix: the
            # warning was right that prose does not belong in shell syntax.
            # See ./WRITING-WRAPPERS.md sections 4, 6 and 10.
            usage = pkgs.writeText "hermes-google-${name}-usage" ''
                usage: hermes-google-${name} <service> <subcommand> [args...]

                  e.g. hermes-google-${name} gmail search 'is:unread' --max 5
                       hermes-google-${name} calendar list

                capabilities (baked in at build time -- change them in
                hermes/users/${agent}.nix, then re-run hermes-google-auth ${name}):
                ${lib.concatMapStringsSep "\n" (c: "  ${c}") acct.capabilities}

                purpose:
                ${lib.concatMapStringsSep "\n" (l: "  ${l}") (lib.splitString "\n" acct.purpose)}

                Run `hermes-google-status ${name}` for live token state.
            '';
        in pkgs.writeShellApplication {
            name = "hermes-google-${name}";
            # `cat` has to come from the closure, not the caller's PATH: these
            # commands also run from systemd units and hooks, which get no login
            # shell.  ./WRITING-WRAPPERS.md section 2.
            runtimeInputs = [ pkgs.coreutils ];
            meta.description = "Google API as the '${name}' account (${lib.concatStringsSep " " acct.capabilities})";
            text = ''
                # Generated by hermes/google/wrappers.nix for agent '${agent}',
                # account '${name}'. Do not edit: a nixos-rebuild overwrites it.
                if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
                    cat ${usage} >&2
                    exit 2
                fi
                export HERMES_GOOGLE_MANIFEST=${manifest}
                exec ${googlePython}/bin/python3 ${script} api ${lib.escapeShellArg name} "$@"
            '';
        }
    ) accounts;

    # The advisory layer, shipped as a STORE PATH referenced from
    # `settings.skills.external_dirs`.  Never copied into ~/.hermes/skills/:
    # hermes.nix deliberately does not manage that tree so a rebuild cannot wipe
    # agent-authored skills, and external_dirs is the sanctioned read-only hatch.
    #
    # Taken from the `skills` registry in hermes/lib.nix rather than built here,
    # so the repo has exactly ONE place that turns hermes/skills/<name>/ into a
    # store path, and dropping in another skill needs no edit here.
    #
    # `config = null` is safe and deliberate: lib.nix only threads `config` into
    # the ./mcp and ./profiles snippets, and Nix is lazy, so reading `.skills`
    # never forces it.  (Same property secrets/secrets.nix relies on.)
    skillsDir = (import ../lib.nix {
        inherit pkgs lib;
        config = null;
    }).skills.google-oauth;
in
{
    inherit manifest skillsDir;
    manifestData = manifestData;

    packages = [ authWrapper statusWrapper gmailWrapper ] ++ perAccountWrappers;
}
