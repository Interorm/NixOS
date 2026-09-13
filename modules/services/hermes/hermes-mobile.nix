# modules/services/hermes/hermes-mobile.nix -- the mobile PWA renderer
#
# NOT a NixOS module: a plain function returning the swapped hermes-agent
# package.  hermes.nix imports it and hands it to the agents that asked for
# it, so the per-agent option lives on the existing agent submodule and the
# `agents` set stays the one place an agent is declared.
#
# WHAT THIS IS
#
# Hermes Desktop is an Electron shell wrapped around a React renderer that
# talks to `hermes dashboard` over HTTP + /api/ws.  sremes/hermes-mobile is
# that same renderer with the Electron shell stripped and a mobile layout pass
# on top: a PWA that runs in the phone's browser against an EXISTING gateway.
# It ships no agent and no backend of its own -- which is the whole reason it
# is safe here.  The 24/7 gateway stays the only process touching state.db,
# exactly as before.  This swaps the UI that gateway serves, nothing else.
#
# WHY A PACKAGE OVERRIDE AND NOT AN ENV VAR
#
# The obvious approach -- point HERMES_WEB_DIST at another directory in the
# agent's .env -- does not work.  hermes-agent's installPhase wraps every
# binary with `makeWrapper --set HERMES_WEB_DIST ...`, and `--set` OVERWRITES
# the inherited value rather than defaulting to it.  A dashboard started with
# HERMES_WEB_DIST pointing elsewhere still serves the stock bundle, silently.
# Verified by running one: the fake dist's marker never appeared in /login.
#
# So the swap has to happen inside the package, before the wrapper is written.
# postInstall is the documented hook for that (hermes-agent's installPhase
# ends with runHook postInstall), and replacing the web_dist symlink there
# leaves every other output -- the venv, the TUI, skills, plugins, locales --
# byte-identical to the upstream build.  The expensive Python venv is reused
# from the store untouched; only the tiny wrapper derivation is rebuilt.
{ lib, pkgs, hermesUpstream, rev, hash }:

let
    src = pkgs.fetchFromGitHub {
        owner = "sremes";
        repo = "hermes-mobile";
        inherit rev hash;
    };

    # The renderer bundle.  Built with hermes-agent's OWN node toolchain
    # (nodejs 26 + npm 12, exposed as the hermesNpmLib passthru) rather than a
    # nixpkgs nodejs: hermes-mobile pins `engines.node = ^22.22 || ^24.11 ||
    # >=26` and `npm <11.10 || >=11.17`, and the fork tracks upstream's
    # toolchain by design.  Reusing the passthru keeps the two in lockstep.
    #
    # importNpmLock resolves every dependency from the lockfile's own
    # `integrity` hashes, so there is no separate npm dependency hash to keep
    # in sync -- the lockfile is the single source of truth.
    mobileWeb = pkgs.buildNpmPackage {
        pname = "hermes-mobile-web";
        version = "0.1.0";
        inherit src;

        nodejs = hermesUpstream.hermesNpmLib.nodejs;

        npmDeps = pkgs.importNpmLock.importNpmLock { npmRoot = src; };
        npmConfigHook = pkgs.importNpmLock.npmConfigHook;

        # The renderer carries Electron as a dev dependency for type-checking
        # even though nothing here runs it.  Without this the fixup phase
        # tries to fetch an Electron binary and the sandbox (correctly)
        # refuses.
        ELECTRON_SKIP_BINARY_DOWNLOAD = 1;

        # The upstream `build` script chains an install guard and a git-based
        # build stamp ahead of vite.  Neither applies in a sandbox -- there is
        # no .git and no npm-installed root -- so vite is invoked directly.
        buildPhase = ''
            runHook preBuild
            cd apps/desktop
            node ../../node_modules/vite/bin/vite.js build --outDir dist
            cd ../..
            runHook postBuild
        '';

        installPhase = ''
            runHook preInstall
            cp -r apps/desktop/dist $out
            runHook postInstall
        '';

        meta = {
            description = "Hermes Desktop renderer as a mobile-first PWA";
            homepage = "https://github.com/sremes/hermes-mobile";
            license = lib.licenses.mit;
        };
    };
in {
    inherit mobileWeb;

    # The agent package with its renderer swapped.
    package = hermesUpstream.overrideAttrs (prev: {
        postInstall = (prev.postInstall or "") + ''
            rm -f $out/share/hermes-agent/web_dist
            ln -s ${mobileWeb} $out/share/hermes-agent/web_dist
        '';
    });
}
