# services/hermes/hermes-desktop-client.nix — Hermes Desktop as a thin remote-gateway client
#
# A standalone NixOS module that installs the Hermes Desktop (Electron) app in
# PURE-CLIENT mode: it attaches to an EXISTING remote gateway and runs no local
# backend, no local gateway service, and keeps its state in a directory of its
# own. It is for a workstation that runs no gateway at all.
#
# ── Standalone on purpose ────────────────────────────────────────────────────
# This file is NOT imported by any default.nix here. The sibling
# engine/hermes.nix is the 24/7 server fleet (it declares agents, gateways and
# system services); this module is the opposite end of the wire — a client for
# a machine that hosts none of that. Importing one from the other would couple
# a workstation that wants only the desktop to the whole fleet schema. So the
# host opts in explicitly:
#
#     imports = [ ./services/hermes/hermes-desktop-client.nix ];
#
#     services.hermes-desktop-client = {
#         enable = true;
#         user = "karl";
#         gatewayUrl = "https://hermes.<tailnet>.ts.net";
#         tokenFile = config.age.secrets."hermes-desktop-token".path;
#     };
#
# ── What "pure client" does and does not mean ────────────────────────────────
# The Electron app resolves its backend through a chain whose last rung is an
# existing `hermes` binary named by HERMES_DESKTOP_HERMES. Upstream bakes that
# binary into the desktop package (nix/desktop.nix sets it unconditionally), so
# a "pure client" still SHIPS a full hermes-agent runtime in its closure — the
# app needs a resolver target. What it does NOT ship is a running gateway or
# backend SERVICE, and it never shares agent STATE with a local agent: the
# launcher points HERMES_HOME at `hermesHome`, deliberately NOT ~/.hermes, so
# the client's sessions/memory/skills live apart from anything a local agent
# owns. Honest claim: no local gateway, no local backend service, no shared
# agent state — not "no local agent".
#
# ── Where the secret goes ────────────────────────────────────────────────────
# The remote URL is non-secret and is baked into the wrapper with --set. The
# TOKEN must never be: makeWrapper writes a --set value into /nix/store, which
# every local user can read. So the token is read from `tokenFile` at launch in
# a --run line (mirroring upstream's own desktopRun pattern), and the guard
# names the path when it cannot be read. `tokenFile` is expected to be an
# agenix decryption under /run/agenix/<name>, consumed by .path only — never a
# plaintext value in the repo.
{
    config, lib, pkgs, inputs,
    ...
}: let
    cfg = config.services.hermes-desktop-client;

    # The desktop package, overridden with the client's environment. `override`
    # (not overrideAttrs): extraEnv/extraRun are arguments to the desktop.nix
    # derivation, and their values land in the wrapper that installPhase writes.
    desktopPackage = cfg.package.override {
        extraEnv = {
            # Non-secret: safe to bake into the store-backed wrapper.
            HERMES_DESKTOP_REMOTE_URL = cfg.gatewayUrl;
            # Point the app at its OWN state dir, not ~/.hermes. A GUI launcher
            # reads no shell profile, so the launcher carries HERMES_HOME itself;
            # without this it would open ~/.hermes and share state with any local
            # agent on the box.
            HERMES_HOME = cfg.hermesHome;
        };

        # The token travels here, never in extraEnv (see header). Read at each
        # start; if the file is missing/unreadable the app would otherwise throw
        # "HERMES_DESKTOP_REMOTE_URL is set but HERMES_DESKTOP_REMOTE_TOKEN is
        # not", so fail loudly and name the path instead.
        extraRun = [ ''
            if [ -r ${lib.escapeShellArg cfg.tokenFile} ]; then
                HERMES_DESKTOP_REMOTE_TOKEN="$(tr -d '\r\n' < ${lib.escapeShellArg cfg.tokenFile})"
                export HERMES_DESKTOP_REMOTE_TOKEN
            else
                echo "hermes-desktop-client: cannot read the gateway token at ${cfg.tokenFile}." >&2
                echo "hermes-desktop-client: the desktop will refuse to connect to the remote gateway." >&2
                exit 1
            fi
        '' ];
    };
in {
    options.services.hermes-desktop-client = {
        enable = lib.mkEnableOption ''
            the Hermes Desktop application (Electron) as a pure client of a
            remote gateway. Installs the desktop for `user`, pointed at
            `gatewayUrl`, with its own HERMES_HOME. Runs no local gateway or
            backend service.
        '';

        user = lib.mkOption {
            type = lib.types.str;
            description = ''
                The user the desktop runs as. Home Manager provisions the
                installation for this account.
            '';
        };

        gatewayUrl = lib.mkOption {
            type = lib.types.str;
            example = "https://hermes.<tailnet>.ts.net";
            description = ''
                The base URL of the remote Hermes gateway to attach to.

                Tailscale is the expected transport: the tailnet is private and
                TLS-terminating, so the token presented to it is not exposed on
                the wire. A bare LAN or plain-HTTP URL ships the token in
                cleartext — do not use one unless the link is trusted end to end.
            '';
        };

        tokenFile = lib.mkOption {
            type = lib.types.path;
            description = ''
                Path to the gateway session token, read at launch and never
                written into the store. Expected to be an agenix decryption
                (/run/agenix/<name>) consumed by .path only. Required: a pure
                client with no token cannot connect, and the upstream app throws
                if the URL is set without the token.
            '';
        };

        package = lib.mkOption {
            type = lib.types.package;
            default = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop;
            defaultText = lib.literalExpression ''inputs.hermes-agent.packages.$${system}.desktop'';
            description = ''
                The hermes-desktop package to install. Defaults to the desktop
                build of the pinned hermes-agent flake input.
            '';
        };

        hermesHome = lib.mkOption {
            type = lib.types.str;
            default = "/home/${cfg.user}/.hermes-client";
            defaultText = lib.literalExpression ''"/home/$${config.services.hermes-desktop-client.user}/.hermes-client"'';
            description = ''
                The HERMES_HOME the desktop uses. Deliberately NOT ~/.hermes: a
                pure client must not share a state directory with any local
                agent, so it gets a directory of its own.
            '';
        };
    };

    config = lib.mkIf cfg.enable {
        # Grafted onto the host's existing home-manager.users.${cfg.user}
        # entry: home.username / home.homeDirectory / home.stateVersion stay
        # where the host (and Home Manager's own defaults) sets them, so this
        # block only carries what the client needs and cannot conflict with
        # the host's own entry.
        home-manager.users.${cfg.user} = {
            # The client itself. The desktop package ships its own XDG
            # launcher entry (share/applications/hermes.desktop); Home Manager
            # registers it for the user from home.packages.
            #
            # Deliberately NOT installed through the upstream hermes Home
            # Manager module's `programs.hermes-agent.desktop.enable`: that
            # block re-derives the wrapper's extraEnv/extraRun from a LOCAL
            # services.hermes-agent (its HERMES_HOME, the local backend
            # address, the local session token) and would overwrite exactly
            # the args a remote client needs. With nothing here enabling that
            # module, no local CLI and no local gateway/backend unit are
            # declared for the user -- that is the "leave it unset" branch,
            # and it is the one that actually avoids a local agent.
            home.packages = [ desktopPackage ];
        };

        assertions = [
            {
                # A relative path would resolve against the build cwd, not the
                # machine, and silently point at the wrong file. Require
                # absolute.
                assertion = lib.strings.hasPrefix "/" (toString cfg.tokenFile);
                message = "services.hermes-desktop-client.tokenFile must be an absolute path (e.g. an agenix .path under /run/agenix/), got: ${toString cfg.tokenFile}";
            }
        ];
    };
}
