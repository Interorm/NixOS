{
    pkgs, lib, config,
    ...
}: let
    cfg = config.services.inference-dnd;

    # One script, four verbs.  The desktop entry calls `toggle`; the right-click
    # actions call `on` / `off` so you can force a state without first having to
    # work out which state you are in.
    #
    # Everything here runs as the desktop user, which is exactly the user the
    # proxy SSHes in as -- so the file it creates is trivially readable by the
    # `test -e` on the other end, with no ownership juggling.
    dnd = pkgs.writeShellScriptBin "dnd" ''
        set -euo pipefail

        FLAG=${lib.escapeShellArg cfg.flagFile}
        DIR=$(dirname "$FLAG")

        notify() {
            # -a groups the notifications so KDE replaces the previous one
            # instead of stacking a new banner every time you flip the switch.
            ${pkgs.libnotify}/bin/notify-send \
                -a "Inference DND" -i "$1" -t 4000 "$2" "$3" || true
        }

        # Best-effort: drop the ~30 GB of weights immediately rather than waiting
        # up to AVAILABILITY_POLL (30 s) for the proxy to notice the flag.  The
        # NOPASSWD rule for this exact path is declared in llama-server.nix; if
        # that module is not on this host the binary simply is not there.
        release_gpu() {
            if [ -x /run/current-system/sw/bin/ninferctl ]; then
                sudo -n /run/current-system/sw/bin/ninferctl stop >/dev/null 2>&1 || true
            fi
        }

        set_on() {
            mkdir -p "$DIR"
            date -Iseconds > "$FLAG"
            release_gpu
            notify network-offline "Do Not Disturb: ON" \
                "The homeserver will not wake this PC or run inference on it."
        }

        set_off() {
            rm -f "$FLAG"
            notify network-transmit-receive "Do Not Disturb: OFF" \
                "The homeserver may wake this PC and run inference again."
        }

        case "''${1:-toggle}" in
            on)     set_on ;;
            off)    set_off ;;
            toggle) if [ -e "$FLAG" ]; then set_off; else set_on; fi ;;
            status)
                if [ -e "$FLAG" ]; then
                    echo "on (since $(cat "$FLAG" 2>/dev/null || echo unknown))"
                else
                    echo "off"
                fi
                ;;
            *) echo "usage: dnd {on|off|toggle|status}" >&2; exit 2 ;;
        esac
    '';

    dndDesktopItem = pkgs.makeDesktopItem {
        name = "inference-dnd";
        desktopName = "Inference: Do Not Disturb";
        comment = "Stop the homeserver from waking this PC for LLM inference";
        exec = "${dnd}/bin/dnd toggle";

        # Named icons from the active theme, so this follows your Plasma theme
        # instead of shipping a bitmap in the store.
        icon = "network-offline";
        terminal = false;
        categories = [ "Utility" "System" ];
        keywords = [ "dnd" "llm" "inference" "ninfer" "gpu" ];

        # Plasma surfaces these in the right-click menu of a pinned launcher.
        actions = {
            on = {
                name = "Turn ON (block remote inference)";
                exec = "${dnd}/bin/dnd on";
            };
            off = {
                name = "Turn OFF (allow remote inference)";
                exec = "${dnd}/bin/dnd off";
            };
        };
    };
in {
    options.services.inference-dnd = {
        user = lib.mkOption {
            type = lib.types.str;
            default = "karl";
            description = ''
                Desktop user who owns this machine.  The flag lives in this
                user's home directory because that is the account the
                homeserver's llama-proxy logs in as -- see PC_USER in
                llama-proxy.py.  Change both together or the proxy will look
                for a file that nothing ever writes.
            '';
        };

        flagFile = lib.mkOption {
            type = lib.types.str;
            readOnly = true;
            default = "/home/${cfg.user}/.llama-proxy/dnd.flag";
            description = ''
                Computed, not settable.  Must stay byte-identical to DND_FLAG in
                llama-proxy.py; exposed here so anything else on this host can
                read the path off the config instead of re-typing it.
            '';
        };
    };

    config = {
        # No systemd.tmpfiles rule for the parent directory on purpose.  tmpfiles
        # runs early at boot and would happily create a root-owned /home/karl if
        # it won the race against user creation.  `mkdir -p` inside the script
        # runs as the user, after login, and cannot get the ownership wrong.
        environment.systemPackages = [ dnd dndDesktopItem pkgs.libnotify ];
    };
}
