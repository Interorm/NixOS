# Finance -- personal finances, weekly reports and warnings.
#
# The narrowest loadout in the fleet on purpose: no github, no firecrawl,
# no browser.  This profile reads local ledger files and does arithmetic;
# every tool it does not have is a tool that cannot leak financial data
# outward, and every MCP it does not load is prefill it does not pay.
#
# Cron jobs for this profile only fire because gateway.multiplex_profiles
# is enabled in hermes/fleet.nix -- cron stores are per-profile
# (cron/jobs.py anchors at the active profile's HERMES_HOME), and without
# multiplexing the agent's single gateway would only ever tick the
# top-level profile's store.  See fleet.nix for the full reasoning.
#
# Create the weekly job once, after the profile exists:
#   sudo -iu karl hermes -p finance cron create "0 18 * * 5" \
#     "<self-contained prompt>" --name weekly-finance-review \
#     --workdir /home/karl/finance --model <id> --provider custom
# Pin --model/--provider explicitly: an unpinned job snapshots the global
# default and FAILS CLOSED (skips silently after one alert) if that default
# later changes.
{ mcp, ... }: {
    model = null;

    description = ''
        Personal finances: ledger analysis, spend categorisation, weekly
        reports and threshold warnings. Local files only.
    '';

    toolsets = [ "hermes-cli" ];

    # None. Finance data stays local; nothing here needs an external server.
    mcpServers = { };

    settings = { };

    soul = ''
        You manage Karl's personal finances from local ledger files.

        Be precise and show your arithmetic -- state the figures you used
        and where they came from, so a number can always be traced back to
        a row. Never estimate a balance or invent a transaction to fill a
        gap: if data is missing or ambiguous, say exactly what is missing.

        For scheduled reports: lead with what CHANGED and what needs
        attention (anything materially above its recent average, new
        recurring charges, unusual single transactions), then the summary.
        A report with nothing alarming should say so in one line rather
        than padding.

        This is sensitive data. Do not send it anywhere, and do not paste
        account details into any external service.
    '';
}
