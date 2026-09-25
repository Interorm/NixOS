# ComfyUI -- local image generation (Karls-PC).
#
# Uses the NATIVE nixpkgs `services.comfyui` module (a hardened systemd unit:
# dedicated `comfyui` system user, ProtectSystem=strict, StateDirectory), with
# the *package* swapped for our overlay build, which tracks upstream instead
# of nixpkgs' lagging version.  See overlays/comfyui.nix for why.
#
# ONE UNIT, TWO SURFACES: ComfyUI serves the web UI and its JSON API from the
# same process on one port.  "the comfy UI" and "the API other services call"
# are the same systemd unit; there is no second port.
#
# SECURITY POSTURE: ComfyUI has NO authentication of any kind -- network
# reachability IS the security boundary, and the Manager can install arbitrary
# custom nodes (i.e. execute arbitrary code) through the web UI.  Therefore
# this listens on loopback only.  Exposing it to the LAN is a deliberate,
# separate decision; the commented block at the bottom is what that takes.
{
  pkgs,
  lib,
  config,
  ...
}:
{
  services.comfyui = {
    enable = true;

    # Overlay build (tracks upstream) with comfyui-manager in the python env.
    # The manager is why this is the -with-manager variant: upstream's
    # main.py silently disables --enable-manager when the package is not
    # importable, so pointing this at the bare build would give a running
    # service with no model/node manager and only a line in the log.
    package = pkgs.comfyui-with-manager;

    # Loopback only.  `listen` is a LIST in the nixpkgs module (the
    # third-party flake called this `listenAddress` and took a string).
    listen = [
      "127.0.0.1"
      "::1"
    ];

    port = 8188;

    # Models, custom nodes, inputs, outputs and the sqlite db.  This is the
    # unit's StateDirectory, created as 0700 comfyui:comfyui; the module
    # seeds the subdirectories from the package on first start.
    #
    # Deliberately NOT in the Nix store: model weights are multi-gigabyte,
    # mutable, and downloaded out of band (Hugging Face / Civitai).
    dataDir = "/var/lib/comfyui";

    extraArgs = [
      # Custom-node and model management from the web UI.  Requires the
      # comfyui-manager package in the env -- see `package` above.
      "--enable-manager"
    ];
  };

  # LAN EXPOSURE (opt-in, currently off).  Uncommenting BOTH of these makes
  # ComfyUI reachable from the rest of the network, with no authentication in
  # front of it.  Only do this on a trusted LAN.
  #
  # services.comfyui.listen = [ "0.0.0.0" "::" ];
  # networking.firewall.allowedTCPPorts = [ config.services.comfyui.port ];
}
