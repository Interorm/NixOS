#!/usr/bin/env bash
# Force every PDF that read_file touches through docling-serve.
#
# Registered as a Hermes `pre_tool_call` shell hook with matcher "read_file".
# Hermes pipes the pending tool call in on stdin as JSON and reads our stdout
# back as JSON; returning {"action":"modify","args":{...}} rewrites the tool
# arguments *before* dispatch.  So we hand read_file the path of a Markdown
# file we just produced, and read_file never sees the PDF at all.
#
# Why this exists: read_file's own PDF path (firecrawl-anydoc) extracts the
# text layer only, so a scanned page silently converts to nothing.  docling
# runs layout + table models over the rendered page and handles both.
#
# Failure is deliberately LOUD (exit 2 = block).  Falling back to the built-in
# extractor would quietly hand the agent worse text with no signal that the
# good path was skipped -- exactly the bug this hook exists to prevent.

# errexit OFF deliberately, overriding writeShellApplication's default: every
# failure path here has to emit either a no-op or a block JSON on stdout, and
# a bare `exit 1` from some unchecked command would emit neither.  With
# fail_closed that silently becomes "PDF reads are broken" instead of a
# message saying why.
set +e
set -uo pipefail

payload="$(cat -)"

# Never let a hook bug take read_file down with it: any unexpected shape is a
# silent no-op, and read_file proceeds exactly as it would without the hook.
nop() { printf '{}\n'; exit 0; }

block() {
    # stdout block JSON is what Hermes reports to the model; exit 2 makes it a
    # block even for callers that ignore the JSON.
    jq -cn --arg m "$1" '{action: "block", message: $m}'
    exit 2
}

path="$(jq -r '.tool_input.path // empty' <<<"$payload" 2>/dev/null)" || nop
[ -n "$path" ] || nop

# Case-insensitive .pdf suffix, and nothing else.
shopt -s nocasematch
[[ "$path" == *.pdf ]] || nop
shopt -u nocasematch

# ~ and relative paths: resolve against the call's cwd the way read_file will.
cwd="$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)"
if [ "$path" = "~" ]; then
    path="$HOME"
elif [ "${path#\~/}" != "$path" ]; then
    # Leading "~/" -- expand it ourselves; the shell did not, since the path
    # arrived as JSON data rather than as a word on a command line.
    path="$HOME/${path#\~/}"
elif [ "${path#/}" = "$path" ] && [ -n "$cwd" ]; then
    path="$cwd/$path"
fi

# A missing or unreadable file is read_file's error to report, with its
# "did you mean" suggestions.  Not ours to pre-empt.
[ -f "$path" ] && [ -r "$path" ] || nop

cache_dir="${HERMES_HOME:-$HOME/.hermes}/cache/docling"
mkdir -p "$cache_dir" || block "docling hook: cannot create $cache_dir"

# Keyed on content, not on path or mtime: the same PDF arriving under a second
# name converts once, and an edited file in place is a different key.
sum="$(sha256sum -- "$path" | cut -d' ' -f1)" || block "docling hook: sha256sum failed on $path"
out="$cache_dir/$sum.md"

if [ ! -s "$out" ]; then
    body="$cache_dir/.$sum.body"
    code="$(curl -sS -X POST "$DOCLING_URL/v1/convert/file" \
        -F "files=@$path" -F 'to_formats=md' \
        --max-time "$DOCLING_TIMEOUT" \
        -o "$body" -w '%{http_code}' 2>"$cache_dir/.$sum.err")" || {
            err="$(tr -d '\n' <"$cache_dir/.$sum.err" | head -c 300)"
            rm -f "$body" "$cache_dir/.$sum.err"
            block "docling unreachable at $DOCLING_URL ($err). PDF '$path' NOT converted; \
docling is the required path for PDFs on this host. Check: systemctl status docker-docling"
        }

    if [ "$code" != "200" ]; then
        rm -f "$body" "$cache_dir/.$sum.err"
        block "docling returned HTTP $code for '$path'. PDF not converted."
    fi

    status="$(jq -r '.status // "unknown"' <"$body" 2>/dev/null)"
    if [ "$status" != "success" ] && [ "$status" != "partial_success" ]; then
        errs="$(jq -rc '.errors // []' <"$body" 2>/dev/null | head -c 300)"
        rm -f "$body" "$cache_dir/.$sum.err"
        block "docling conversion status='$status' for '$path': $errs"
    fi

    # md_content is null when docling produced no Markdown; an empty file here
    # would be cached as a successful empty conversion.
    if ! jq -e '.document.md_content != null' <"$body" >/dev/null 2>&1; then
        rm -f "$body" "$cache_dir/.$sum.err"
        block "docling returned no Markdown for '$path' (md_content was null)."
    fi

    if ! {
        printf '<!-- Converted from %s by docling-serve at %s.\n' "$path" "$DOCLING_URL"
        jq -r '"     confidence: \(.confidence.mean_grade // "?") (mean \(.confidence.mean_score // 0 | .*100 | floor)%), pages parsed by layout+table models, not the PDF text layer. -->"' <"$body"
        jq -r '.document.md_content' <"$body"
    } >"$out.tmp"; then
        rm -f "$body" "$cache_dir/.$sum.err" "$out.tmp"
        block "docling hook: failed writing $out"
    fi

    if ! mv -f "$out.tmp" "$out"; then
        rm -f "$body" "$cache_dir/.$sum.err" "$out.tmp"
        block "docling hook: failed installing $out"
    fi

    rm -f "$body" "$cache_dir/.$sum.err"
fi

# Rewrite only `path`.  Hermes shallow-merges this over the original args, so
# offset/limit the model asked for still apply -- to the Markdown.
jq -cn --arg p "$out" '{action: "modify", args: {path: $p}}'
