# Home Assistant, full access.  HA_URL_FULLACCESS comes from the consuming
# agent's own secret file (see secrets/hermes-<name>.age) and is resolved by
# Hermes at runtime -- never by Nix, so no URL or token reaches the store.
#
# Reached over Tailscale, not the public internet; no port forwarding.
{ ... }: {
    url = "\${HA_URL_FULLACCESS}";
}
