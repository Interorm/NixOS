#!/usr/bin/env bash
#
# review-agent-patch.sh — safety gate for agent-proposed NixOS config changes.
#
# The Hermes agents (karl, joni) may PROPOSE changes to this repo, but they may
# not apply or push them.  An agent workflow looks like:
#
#     1. work in a clean clone or worktree
#     2. git diff main > /tmp/proposal.diff
#     3. scripts/review-agent-patch.sh /tmp/proposal.diff   <- this script
#     4. push a branch + open a PR (the human reviews and merges)
#
# This script is read-only: it never applies the patch and never pushes.  It
# answers exactly one question -- "is this patch clean and entirely inside the
# area the agent is allowed to touch?" -- and exits 0 only if the answer is
# yes.  It prints a human-readable summary either way, so the person reviewing
# the PR sees the same verdict the agent saw.
#
# Checks performed:
#   1. the patch applies cleanly to a fresh clone (`git apply --check`)
#   2. every touched path is inside the allowlist (prefix match)
#   3. no binary files (opaque diffs are not reviewable)
#   4. no obvious hardcoded secrets (heuristic: KEY/TOKEN/SECRET/PASSWORD
#      assignments whose value is a long literal, not a `${VAR}` reference)
#
# Usage:
#   scripts/review-agent-patch.sh <patch-file>
#   cat proposal.diff | scripts/review-agent-patch.sh -
#
# Environment:
#   REVIEW_REPO    repo to check against (default: this repo's origin)
#   REVIEW_ALLOW   extra allowlist entries, one per line (default: see below)

set -euo pipefail

# --- allowlist -------------------------------------------------------------
# Paths an agent may propose changes to.  Deliberately narrow: the agent can
# tune the MCP fleet and the agent profiles, but CANNOT touch the flake itself
# (inputs = supply chain), the review script (this file = the gate), host
# hardware, or the module structure.  Widen it deliberately and by hand.
ALLOWLIST=(
    # the MCP fleet declaration
    "modules/services/hermes/mcps.nix"
    # the shared Lean setup
    "modules/development/lean-math.nix"
    # per-host agent profiles (models, souls, ports, secrets wiring)
    "hosts/*/hermes_profiles.nix"
    # per-person home configuration
    "home/*/git.nix"
    "home/*/default.nix"
)

if [[ -n "${REVIEW_ALLOW:-}" ]]; then
    while IFS= read -r extra; do
        [[ -n "$extra" ]] && ALLOWLIST+=("$extra")
    done <<<"$REVIEW_ALLOW"
fi

PATCH="${1:?usage: review-agent-patch.sh <patch-file|->}"
REPO="${REVIEW_REPO:-}"

# --- read the patch --------------------------------------------------------
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
if [[ "$PATCH" == "-" ]]; then
    cat >"$tmpdir/proposal.diff"
else
    cp "$PATCH" "$tmpdir/proposal.diff"
fi
DIFF="$tmpdir/proposal.diff"

if [[ ! -s "$DIFF" ]]; then
    echo "VERDICT: REJECT -- empty patch."
    exit 1
fi

# --- fresh clone to test against -------------------------------------------
if [[ -z "$REPO" ]]; then
    # default: the origin of the clone the script lives in (if any)
    REPO="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" remote get-url origin 2>/dev/null || true)"
fi
if [[ -z "$REPO" ]]; then
    REPO="https://github.com/Interorm/NixOS"
fi

CLONE="$tmpdir/repo"
if ! git clone --depth 1 "$REPO" "$CLONE" 2>"$tmpdir/clone.log"; then
    echo "VERDICT: REJECT -- could not clone $REPO:"
    cat "$tmpdir/clone.log"
    exit 1
fi
cd "$CLONE"

# --- check 1: does the patch apply cleanly? --------------------------------
if ! git apply --check "$DIFF" 2>"$tmpdir/apply.log"; then
    echo "VERDICT: REJECT -- patch does not apply cleanly:"
    cat "$tmpdir/apply.log"
    exit 1
fi
echo "check 1/4: patch applies cleanly ............ OK"

# --- check 2: allowlist -----------------------------------------------------
# Touched files, from the patch headers (handles both `diff --git` and
# `--- a/...` forms; deduplicated).
touched="$(
    grep -E '^(diff --git a/|--- a/|\+\+\+ b/)' "$DIFF" \
        | sed -E 's/^diff --git a\/([^ ]+).*/\1/; s/^--- a\/(.*)$/\1/; s/^\+\+\+ b\/(.*)$/\1/' \
        | grep -vE '^(/dev/null|a/|b/)$' \
        | sort -u
)"

outside=()
inside=()
for path in $touched; do
    matched=0
    for allow in "${ALLOWLIST[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$path" == $allow ]]; then
            matched=1
            break
        fi
    done
    if [[ $matched -eq 1 ]]; then
        inside+=("$path")
    else
        outside+=("$path")
    fi
done

if [[ ${#outside[@]} -gt 0 ]]; then
    echo "VERDICT: REJECT -- patch touches paths outside the agent allowlist:"
    printf '  %s\n' "${outside[@]}"
    echo
    echo "A human must make these changes (or explicitly widen the allowlist"
    echo "in this script and re-run). Files the patch DID touch that are allowed:"
    printf '  %s\n' "${inside[@]:-  (none)}"
    exit 1
fi
echo "check 2/4: paths inside allowlist ........... OK (${#inside[@]} file(s))"

# --- check 3: no binary diffs ----------------------------------------------
if grep -qE '^(Binary files|GIT binary patch)' "$DIFF"; then
    echo "VERDICT: REJECT -- patch contains binary content (not reviewable)."
    exit 1
fi
echo "check 3/4: no binary files .................. OK"

# --- check 4: no obvious hardcoded secrets ----------------------------------
# Heuristic: an assignment like  FOO_TOKEN=abc123...  (long literal) is
# suspicious;  FOO_TOKEN="${BAR}"  (variable reference) is fine.  This is a
# tripwire, not a guarantee -- the PR review is the real gate.
secrets="$(
    grep -nE '^\+.*[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY|_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*["'\'']?([^"'\''$[:space:]]{16,})' \
        "$DIFF" || true
)"
if [[ -n "$secrets" ]]; then
    echo "VERDICT: REJECT -- patch appears to contain a hardcoded secret:"
    echo "$secrets"
    echo
    echo "Secrets belong in /etc/hermes/<agent>.env (outside the repo) and are"
    echo "referenced as \${VAR} in config, per hermes.nix."
    exit 1
fi
echo "check 4/4: no obvious hardcoded secrets ...... OK"

# --- verdict -----------------------------------------------------------------
echo
echo "VERDICT: APPROVED-FOR-PR -- patch is clean and inside the allowlist."
echo "Files touched:"
printf '  %s\n' "${inside[@]}"
echo
echo "Next steps (human or agent):"
echo "  1. push the branch:   git push origin HEAD:refs/heads/<branch>"
echo "  2. open the PR and show this summary in the description"
echo "  3. a human reviews and merges; the change lands on the next"
echo "     nixos-rebuild switch (which stays the final gate either way)."
exit 0
