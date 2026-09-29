# The FinTS MCP server as a store-path application.
#
# Split out of ../fints.nix because that file is the *registry snippet*:
# hermes/lib.nix turns every regular hermes/mcp/*.nix into plain data for
# `mcpServers`, so it must evaluate to `{ command; args; env; }` and cannot
# also hand a package to `hermes/users/karl.nix` for the agent's PATH.  Both
# import this file, so there is exactly one derivation and the MCP server and
# the enrolment CLI can never be built from different sources.
#
# (A directory under hermes/mcp/ is invisible to the registry -- loadDir only
# takes `type == "regular"` entries -- so this file adds no `mcp.*` attribute.)
#
# WHY THESE PRIMITIVES, and not pkgs.python3.application: this pinned nixpkgs
# no longer ships `python3.application` (the 2026 python rewrite dropped it);
# see the same note in ../onedrive.nix.  `lib.fileset.toSource` +
# `writeShellScriptBin` give the same shape -- a store path exposing bin/ --
# with no new packages and no flake inputs.  (../onedrive.nix uses
# `copyPathToStore` on a single file; see the source note below for why that
# primitive is the wrong one for a whole directory.)
#
# WHY THE WHOLE DIRECTORY, not a single file: unlike the OneDrive server, which
# imports nothing, mcp_server.py does
#     sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
#     import db, fints_client
# and enroll.py imports the same two.  `copyPathToStore ./mcp_server.py` would
# build perfectly and then fail at runtime with ModuleNotFoundError on the
# first tool call -- i.e. only after a rebuild.  Copying the package directory
# keeps the sibling imports resolvable from the store path.
#
# Rebuild-proof: the flake checkout is mutable on `git pull`, so nothing at
# runtime may point at a checkout or a home path.  `./.` here resolves inside
# the flake's own source, which is content-addressed -- so the store copy is
# byte-for-byte the code at the flake's revision.
#
# THE SOURCE IS AN EXPLICIT ALLOWLIST, NOT THE BARE DIRECTORY, and that is
# load-bearing rather than tidiness.  A plain `copyPathToStore ./.` copies
# whatever is in the directory at eval time, and a *dirty* flake tree hands
# Nix more than git tracks: verified on nix 2.34.8 by dropping a finance.db
# and a fints_state.json into this directory -- `git status` correctly ignored
# both (hermes/mcp/fints/.gitignore), and both still landed in the flake
# source AND in the store copy, 0444, world-readable, forever.  That is the
# whole bank database published to every user on the box.  The state file and
# the DB really live in ~/.hermes/finance/, so this needs a stray copy to bite
# -- but the package's own README tells you to run test_harness.py from this
# directory, and __pycache__/ arrived by exactly that route.
#
# `fileFilter (hasExt "py")` + the fixtures dir therefore states what goes in.
# A new *.py module (the labeling card adds some) is picked up automatically,
# while .db/.json/.lock/.pyc cannot be, whatever the working tree looks like.
{ pkgs }:

let
    inherit (pkgs) lib;

    # python-fints 5.0.0, straight out of the pinned nixpkgs: no overlay, no
    # extra flake input, no vendoring.  This is the one real difference from
    # ../onedrive.nix, whose server is stdlib-only and runs on bare
    # `pkgs.python3`.
    python = pkgs.python3.withPackages (ps: [ ps.fints ]);

    src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
            (lib.fileset.fileFilter (file: file.hasExt "py") ./.)
            ./fixtures
        ];
    };


    mcp = pkgs.writeShellScriptBin "fints-mcp" ''
        exec ${python}/bin/python3 ${src}/mcp_server.py "$@"
    '';

    # One-time (and ~every 180 days) interactive pushTAN enrolment.  It is the
    # single bootstrap step this feature needs -- see ../fints.nix -- and it
    # needs the same credentials the MCP server gets, which for an
    # interactive shell are not in the environment: the agent's .env is read
    # by Hermes, not by login.  So the wrapper loads it the way a shell loads
    # an env file, which keeps the credentials off the command line (and out
    # of the terminal scrubber's way).
    #
    # HERMES_ENV_FILE overrides the path, for a sub-profile's .env or a test.
    # `set -a` exports every assignment; a value containing shell
    # metacharacters must be quoted in the .env, as for any sourced env file.
    enroll = pkgs.writeShellScriptBin "fints-enroll" ''
        envfile="''${HERMES_ENV_FILE:-$HOME/.hermes/.env}"
        if [ ! -r "$envfile" ]; then
            echo "fints-enroll: cannot read $envfile" >&2
            echo "  (expected the agent's Hermes .env, merged from /run/agenix/hermes-<agent>)" >&2
            exit 1
        fi
        set -a
        # shellcheck disable=SC1090
        . "$envfile"
        set +a
        # Name itself in the script's own messages, matching what
        # ../fints.nix puts in the MCP server's environment.
        export FINTS_ENROLL_CMD="''${FINTS_ENROLL_CMD:-fints-enroll}"
        exec ${python}/bin/python3 ${src}/enroll.py "$@"
    '';
in
pkgs.symlinkJoin {
    name = "fints-mcp";
    paths = [ mcp enroll ];
    meta = {
        description = "Read-only FinTS/HBCI MCP server and pushTAN enrolment CLI";
        mainProgram = "fints-mcp";
    };
}
