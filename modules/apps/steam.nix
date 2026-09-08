{
    pkgs, lib,
    ...
}: {
    programs.steam = {
        enable = true;

        remotePlay.openFirewall = true;                 # 27031-27036
        localNetworkGameTransfers.openFirewall = true;  # 27040
        dedicatedServer.openFirewall = false;           # 27015-27016; only if
                                                        # you host servers

        # Steam's bundled Proton lags behind.  Packages listed here are exposed
        # through STEAM_EXTRA_COMPAT_TOOLS_PATHS, so GE-Proton shows up in the
        # per-game "Compatibility" dropdown without protonup ever running.
        extraCompatPackages = [ pkgs.proton-ge-bin ];

        # Adds a "Steam (gamescope)" session to the display manager -- a
        # console-like fullscreen Big Picture session.  Harmless if unused.
        gamescopeSession.enable = true;
    };

    # Micro-compositor.  Used for per-game resolution scaling, framerate limits
    # and FSR upscaling; launch options become e.g.
    #   gamescope -W 3840 -H 2160 -r 144 -- %command%
    programs.gamescope = {
        enable = true;

        # Grants CAP_SYS_NICE so gamescope can raise its own scheduling
        # priority.  If gamescope ever refuses to start a game, this is the
        # first thing to flip off -- the capability wrapper is a known source
        # of launch failures on some setups.
        capSysNice = true;
    };

    # CPU governor / IO priority switching around a game's lifetime.  Applied
    # via the launch option `gamemoderun %command%`.
    programs.gamemode.enable = true;

    # udev rules + uinput for Steam Controller, Index base stations, etc.
    # programs.steam.enable already pulls this in, but stating it makes the
    # intent explicit and survives a future refactor of the upstream module.
    hardware.steam-hardware.enable = true;

    environment.systemPackages = with pkgs; [
        mangohud     # in-game overlay; launch option `mangohud %command%`
        protonup-qt  # GUI for managing Proton-GE outside of Nix, if you want it
    ];

    # NOTE: Steam is unfree, and the 32-bit graphics stack is mandatory.
    # Both are already handled -- allowUnfree in modules/development/cuda.nix
    # and modules/hardware/nvidia.nix, hardware.graphics.enable32Bit in
    # modules/hardware/nvidia.nix.  If you ever import steam.nix on a host
    # without nvidia.nix, you must set enable32Bit there yourself.
}
