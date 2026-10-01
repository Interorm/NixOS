# Writing wrappers in Nix

A worked guide to building command-line programs from a NixOS module, using the
Google wrappers in this directory as the running example. Written for someone who
reads Nix comfortably but has not written a wrapper before.

Every snippet is runnable. Every claim about a builder was checked against the
nixpkgs revision this flake pins — the APIs here are not quoted from memory, and
section 1 includes the one-liner that re-checks them if the pin moves.

Contents:

1. [The builders, and when to use which](#1-the-builders-and-when-to-use-which)
2. [`runtimeInputs` and PATH hygiene](#2-runtimeinputs-and-path-hygiene)
3. [The `${}` collision — the #1 gotcha](#3-the--collision--the-1-gotcha)
4. [Quoting user data](#4-quoting-user-data)
5. [Baking config in vs reading it at runtime](#5-baking-config-in-vs-reading-it-at-runtime)
6. [Passing structured data](#6-passing-structured-data)
7. [Shipping a script that lives in this repo](#7-shipping-a-script-that-lives-in-this-repo)
8. [Generating N wrappers from an attrset](#8-generating-n-wrappers-from-an-attrset)
9. [Testing a wrapper without root](#9-testing-a-wrapper-without-root)
10. [Pitfalls](#10-pitfalls)

---

## 1. The builders, and when to use which

A "wrapper" is a derivation whose output is `$out/bin/<name>` — an executable
script with its dependencies and configuration already resolved. Nixpkgs gives you
five ways to make one. They are not interchangeable.

### `pkgs.writeShellApplication` — the default choice

```nix
pkgs.writeShellApplication {
  name = "hermes-google-status";
  runtimeInputs = [ pkgs.coreutils pkgs.jq ];
  text = ''
    jq -r '.accounts | keys[]' "$1"
  '';
}
```

What you get, that the others do not:

- **shellcheck runs at build time and findings FAIL the build.** This is a real
  gate, not a lint suggestion. It caught a genuine bug while this PR was being
  written (see §10) and it will reject working-looking code.
- `set -o errexit -o nounset -o pipefail` prepended, so an unchecked failure stops
  the script instead of continuing with a wrong value.
- `runtimeInputs` → a `PATH` prefix, so the script does not depend on the caller's
  environment (§2).
- `meta.description`, `derivationArgs`, `excludeShellChecks` when you need them.

Use it unless you have a specific reason not to. All four Google wrappers use it.

**The one caveat worth knowing:** `errexit` is wrong for a script whose contract is
"always print valid JSON on stdout" (a Hermes hook, anything a caller parses). An
unchecked failure there exits silently with no output and the caller sees a
protocol violation rather than an error. For those, `set +e` at the top and check
commands explicitly.

### `pkgs.writeShellScriptBin` — the minimal one

```nix
pkgs.writeShellScriptBin "onedrive-mcp" ''
  exec ${pkgs.python3}/bin/python3 ${pkgs.copyPathToStore ./onedrive/mcp_server.py} "$@"
''
```

That is the real `hermes/mcp/onedrive.nix`. Two positional arguments, a `#!` line,
and nothing else: **no shellcheck, no `set -e`, no `runtimeInputs`**.

Correct here, because the script is one `exec` line with every path absolute — it
uses no command from `PATH` at all, so there is nothing for `runtimeInputs` to
contribute and nothing for shellcheck to find. For anything with control flow,
prefer `writeShellApplication`; dropping the gate to save three lines is a bad
trade.

### `pkgs.writeScriptBin` — the generic one

Same shape, but you supply the shebang yourself. Needed for a non-shell
interpreter when you are not going through a dedicated writer:

```nix
pkgs.writeScriptBin "my-tool" ''
  #!${pkgs.python3}/bin/python3
  print("hello")
''
```

Note the interpolation inside the shebang: `#!/usr/bin/env python3` in a store
script is a bug waiting for a different `PATH`.

For Python specifically, prefer the dedicated writers — they add a syntax/lint gate
the generic one lacks:

```nix
pkgs.writers.writePython3 "hermes-prune-mcp"
  { libraries = [ pkgs.python3Packages.pyyaml ]; flakeIgnore = [ "E501" ]; }
  ''
    import yaml
    ...
  '';
```

That is the real `pruneMcpScript` in `modules/services/hermes/hermes.nix`.

### `runCommand` + `makeWrapper` — full control

When you need the output to be something other than "one script": several
binaries, extra files alongside, a `share/` tree.

```nix
pkgs.runCommand "my-tool" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
  mkdir -p $out/bin
  makeWrapper ${pkgs.hello}/bin/hello $out/bin/my-hello \
    --prefix PATH : ${pkgs.coreutils}/bin \
    --set GREETING_LANG de \
    --add-flags "--greeting=Hallo"
''
```

`makeWrapper` writes a tiny shell script that sets the environment and then `exec`s
the real binary. §2 shows what it actually generates.

### `symlinkJoin` + `wrapProgram` — wrapping an existing package

When the thing you want already exists in nixpkgs and only needs an environment
tweak. This is the only correct way to "wrap a package": you cannot `wrapProgram`
inside a package's own output, because store paths are read-only.

```nix
pkgs.symlinkJoin {
  name = "ffmpeg-with-env";
  paths = [ pkgs.ffmpeg ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/ffmpeg --set FFREPORT level=32
  '';
}
```

`symlinkJoin` makes a *writable* directory of symlinks into the original; then
`wrapProgram` replaces the one symlink you name with a wrapper that calls through
to it. The rest of the package is untouched.

Note the ordering trap: `wrapProgram` on a path that is still a symlink into the
original store path would try to write there. `symlinkJoin` + `postBuild` is what
makes it legal, and `wrapProgram` handles the dance (it renames to
`.<name>-wrapped` and writes the wrapper in place).

### Summary

| Builder | shellcheck | `set -e` | `runtimeInputs` | Output shape | Use when |
|---|---|---|---|---|---|
| `writeShellApplication` | **yes (fails build)** | yes | yes | one script | **default for a shell wrapper** |
| `writeShellScriptBin` | no | no | no | one script | one `exec` line, all paths absolute |
| `writeScriptBin` | no | no | no | one script | non-shell interpreter, no writer available |
| `writers.writePython3` | flake8 | n/a | `libraries` | one script | Python inline in Nix |
| `runCommand` + `makeWrapper` | no | no | manual `--prefix` | anything | several binaries / extra files |
| `symlinkJoin` + `wrapProgram` | no | no | manual `--prefix` | a modified package | wrapping an existing package |

### Check the API before relying on it

The flake pins `nixos-unstable`, a moving target: an API that existed last year may
be gone in the locked revision. `pkgs.python3.application` is the cautionary tale —
the classic "wrap a Python script as a store-path application" helper, **removed in
the 2026 python rewrite**, and `onedrive.nix` carries a comment about having to
rebuild it from primitives.

```bash
# the nixpkgs source this flake actually pins
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath'

# then probe the attributes you plan to use
nix eval --json --impure --expr '
let pkgs = import <that-outPath> { system = "x86_64-linux"; };
in { writeShellApplication = pkgs ? writeShellApplication;
     copyPathToStore      = pkgs ? copyPathToStore;
     py3application       = (pkgs.python3 or {}) ? application; }'
```

Verified against this flake's pin: `writeShellApplication` ✓,
`writeShellScriptBin` ✓, `copyPathToStore` ✓, `writeText` ✓,
`python3.application` ✗.

---

## 2. `runtimeInputs` and PATH hygiene

### Why a wrapper must not inherit the caller's PATH

A script you test from your interactive shell runs with *your* `PATH`: coreutils,
jq, curl, git, everything in your profile. The same script invoked by

- a **systemd user unit** (no login shell, a minimal `PATH`),
- a **Hermes hook** (a bare subprocess, no shell profile),
- a **cron job**, or
- **another user**

gets almost nothing. `jq: command not found` at 3am, on a machine where the script
"obviously works", is the single most common wrapper bug.

`runtimeInputs` fixes it by putting the dependencies in the derivation's closure
and prefixing their `bin` directories onto `PATH`:

```nix
pkgs.writeShellApplication {
  name = "hermes-docling-pdf-hook";
  runtimeInputs = with pkgs; [ jq curl coreutils ];   # closed over, no PATH assumptions
  text = builtins.readFile ./docling-pdf-hook.sh;
}
```

That is the real `doclingHook`. It is spawned by Hermes as a bare subprocess —
exactly the case with no profile.

### What it actually generates

Read the built script. This is `hermes-google-agent`, which needs `cat`:

```
$ cat $(nix-store -r <drv>)/bin/hermes-google-agent
#!/nix/store/…-bash-5.3p15/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export PATH="/nix/store/…-coreutils-9.11/bin:$PATH"
…
```

A **prefix**, not a replacement: your binaries win, the caller's `PATH` is still
reachable behind them. `makeWrapper --prefix PATH : <dir>` generates the same
thing (`--suffix` appends instead, letting the caller override — rarely what you
want, since it reintroduces the uncertainty).

Compare `hermes-google-status`, whose `runtimeInputs = [ ]`:

```
export PATH="$PATH"
```

An honest no-op, and the thing to check when a dependency is missing.

### The hygiene rules

1. **List every external command the script calls.** shellcheck does not catch a
   missing `runtimeInputs` — the command is valid shell, just absent at runtime.
2. **State `runtimeInputs = [ ]` explicitly when there genuinely are none**, as
   three of the four Google wrappers do. It reads as "checked, none needed" rather
   than "forgot".
3. **Shell builtins need nothing.** `echo`, `[`, `export`, `exec`, `cd` are in
   bash. `cat`, `install`, `chmod`, `ls` are coreutils and must be listed.
4. **An absolute store path needs nothing either.** The Google wrappers `exec`
   `${googlePython}/bin/python3` by full path, so python is in the closure via the
   string reference without being on `PATH` at all. That is the tightest form: the
   interpreter cannot be shadowed by anything.
5. **Verify from a scrubbed environment**, not your shell (§9).

---

## 3. The `${}` collision — the #1 gotcha

**Nix interpolates `${...}` before bash ever sees the text.** Both languages use
the same syntax for completely different things, and Nix wins.

```nix
# WRONG -- Nix tries to evaluate `HOME` as a Nix variable
text = ''
  echo "${HOME}"
'';
# error: undefined variable 'HOME'
```

If a Nix variable of that name happens to exist, there is no error at all — you
silently get the Nix value baked in at build time instead of the shell's runtime
value. That is the dangerous version.

Escape a shell variable inside a `''…''` string by doubling the leading quote:

```nix
# RIGHT -- ''${ is a literal ${ in the output
text = ''
  echo "''${HOME}"
  : "''${TIMEOUT:=30}"      # shell default-assignment, untouched by Nix
'';
```

Inside a `"…"` (double-quoted) Nix string, the escape is a backslash instead:

```nix
env.ONEDRIVE_CLIENT_ID = "\${ONEDRIVE_CLIENT_ID}";
```

That is the real line in `hermes/mcp/onedrive.nix`. The literal `${ONEDRIVE_CLIENT_ID}`
reaches Hermes' MCP config, and *Hermes* resolves it from the agent's `.env` at
runtime — which is the whole point: no secret is ever in the Nix store. Had the
backslash been omitted, Nix would have failed with `undefined variable`, and in a
worse case would have inlined a real secret into a world-readable store path.

Side by side:

| You want in the output | Inside `''…''` | Inside `"…"` |
|---|---|---|
| the Nix value of `foo` | `${foo}` | `${foo}` |
| a literal `${foo}` | `''${foo}` | `\${foo}` |
| a literal `''` | `'''` | `''` |
| a literal `$` | `''$` or `\$` | `\$` |

**Positional parameters are safe.** `"$@"`, `"$1"`, `"$#"` have no brace, so Nix
does not touch them — which is why the Google wrappers can write `"$@"` plainly.

**Verification is cheap and you should always do it:** build the wrapper and read
the result (§9). A `${VAR}` that survived into the output is a `${VAR}` bash will
expand; one that vanished was eaten by Nix.

---

## 4. Quoting user data

Any value that came from an option is attacker-or-typo-controlled as far as the
script is concerned. A path with a space, an apostrophe in prose, a `;` in a
string: string-concatenating it into shell source is a bug, sometimes a serious one.

### `lib.escapeShellArg` / `lib.escapeShellArgs`

```nix
# WRONG -- a space in the path splits into two arguments
text = ''
  install -D -m 0600 ${cfg.source} ${cfg.dest}
'';

# RIGHT
text = ''
  install -D -m 0600 ${lib.escapeShellArg cfg.source} ${lib.escapeShellArg cfg.dest}
'';
```

`escapeShellArg` single-quotes the value and escapes any embedded single quotes.
`escapeShellArgs` does the same for a list, space-joined — the real
`hermesPruneMcp` activation entry uses it to pass a list of MCP server names:

```nix
${lib.escapeShellArgs (lib.attrNames (cfg.mcpServers // agent.mcpServers))}
```

A name with a space would otherwise become two arguments, and the script would
prune the wrong set.

Note the quoting is *for the shell*, applied at build time to a value Nix already
knows. It is not a substitute for quoting runtime variables: `"$1"` still needs its
double quotes.

### When escaping is not enough: take the data out of the script

Escaping works for short, flat values. It does not scale to **multi-line free
prose**, and this PR hit exactly that wall.

The per-account wrapper first printed each account's `purpose` as a generated
`echo` line. `purpose` is prose Karl writes, and it contains backticks:

```
separately by `hermes-google-status` when it exists.
```

`writeShellApplication`'s shellcheck gate **failed the build**:

```
In …/bin/hermes-google-agent line 25:
    echo '    separately by `hermes-google-status` when it exists.' >&2
         ^-- SC2016 (info): Expressions don't expand in single quotes…
```

The tempting fix is `excludeShellChecks = [ "SC2016" ]`. That would be wrong:
the warning was *correct* that prose does not belong in shell syntax, and the next
piece of prose would have found a different hole. The right fix takes the data out
of the script entirely (§6):

```nix
usage = pkgs.writeText "hermes-google-${name}-usage" ''
  usage: hermes-google-${name} <service> <subcommand> [args...]
  purpose:
  ${lib.concatMapStringsSep "\n" (l: "  ${l}") (lib.splitString "\n" acct.purpose)}
'';
# …
text = ''
  if [ "$#" -lt 1 ] || [ "$1" = "--help" ]; then
      cat ${usage} >&2
      exit 2
  fi
'';
```

Now the prose is file content, not shell source. No escaping, no gate to silence,
and `cat` cannot misinterpret anything. The general rule: **escape values, extract
documents.**

---

## 5. Baking config in vs reading it at runtime

Two ways to get a value into a wrapper, with different guarantees.

| | Baked in (store path / interpolated literal) | Read at runtime (env var / argument) |
|---|---|---|
| Reproducible | yes — the value is part of the derivation | no |
| Changing it | a rebuild, i.e. a reviewed commit | anyone who can set the variable |
| Visible in `/nix/store` | **yes — never a secret** | no |
| Validated | at eval time, by the module system | not at all, unless the script checks |
| Flexible | no | yes |

### Why the Google wrappers bake the scopes

The agent is the one running these commands. Every OAuth scope, token path and
account name is interpolated by Nix:

```nix
runner = verb: ''
  export HERMES_GOOGLE_MANIFEST=${manifest}
  exec ${googlePython}/bin/python3 ${script} ${verb} "$@"
'';
```

and the per-account wrapper hardcodes its own account:

```nix
exec ${googlePython}/bin/python3 ${script} api ${lib.escapeShellArg name} "$@"
```

There is deliberately **no** `--scope` flag and **no** `HERMES_SCOPES` variable. An
agent that could pass its own scope list could widen its own Google grant without
anybody reviewing it; an agent that could point `HERMES_GOOGLE_MANIFEST` at a file
it had just written could do the same. With the policy baked in, **the only way to
change what the agent may request is a git commit Karl merges.**

Be precise about what this buys. It is a *correctness and clarity* property, not a
hard boundary: an agent with shell access can always run python directly. The hard
boundary is the set of scopes inside the minted token, which Google checks on every
API call. What baking buys is that the *supported path cannot drift from the
config* — and that is worth a lot, because the common failure is confusion, not
malice.

### When to read at runtime instead

- **Anything secret.** A baked-in value is in the world-readable store. The client
  secret is passed as a **path** (`/run/agenix/google-karl`, tmpfs, 0400) and read
  by the script at runtime. Consume a secret by `.path`, never by value.
- **Anything per-invocation.** Which account, which search query, which calendar.
- **Anything the user must be able to override without a rebuild**, e.g. a timeout
  during debugging — and when you do this, give it a baked default:
  `: "''${TIMEOUT:=30}"`.

### The derivation-identity consequence

A baked value is part of the derivation, so changing it changes the store path.
That is a feature: `nixos-rebuild` shows a new path, the old one stays on disk
until GC, and a rollback restores the exact previous behaviour. It also means a
store path is **stable only if the inputs are** — which is why `scopesFor` in
`hermes/google/default.nix` sorts its output. Without the sort, reordering a
capability list in a user file would change the manifest's bytes, its store path,
and every wrapper that references it, for no functional reason.

---

## 6. Passing structured data

A wrapper often needs more than a few scalars — a table, a nested policy, a list of
lists. Three options, in increasing order of goodness.

### Bad: a heredoc inside the Nix string

```nix
text = ''
  cat <<'EOF' > /tmp/config.json
  {"accounts": {"agent": {"scopes": [...]}}}
  EOF
'';
```

Avoid. **Nix strips only the *common* indentation from a `''` string**, so an
indented heredoc terminator stays indented, the heredoc never closes, and the rest
of the script is swallowed as data. The failure is bizarre and far from the cause.
The content is also unreadable, unparseable by any tool, and impossible to diff.

### Good: `builtins.toJSON` + `pkgs.writeText`

```nix
manifestData = {
  inherit agent clientSecretFile hermesHome;
  redirectUri = "http://localhost:1";
  reference = google.reference;
  accounts = lib.mapAttrs (name: acct: {
    inherit (acct) capabilities address purpose publishing project;
    scopes = google.scopesFor acct.capabilities;
    tokenPath = "${hermesHome}/google/${name}/google_token.json";
  }) accounts;
};

manifest = pkgs.writeText "hermes-google-accounts-${agent}.json"
  (builtins.toJSON manifestData);
```

Then one line in the wrapper:

```nix
export HERMES_GOOGLE_MANIFEST=${manifest}
```

What this buys:

- **Nix data structures all the way.** `lib.mapAttrs`, `lib.unique`, `//` — no
  string-templating a serialisation format by hand.
- **Correct escaping for free.** `builtins.toJSON` handles the newlines, quotes and
  backticks in `purpose` that defeated the `echo` approach in §4.
- **Independently inspectable**, which is what tier-3 validation needs:
  ```bash
  python3 -m json.tool /nix/store/…-hermes-google-accounts-karl.json
  ```
- **A real reference**, so the wrapper has the manifest in its closure and cannot
  be deployed without it.
- Same shape for any format: `pkgs.formats.yaml`/`toml`/`ini` give you a
  `generate` function with a type to match.

### Two rules for the generated file

1. **No secrets.** It lands in the world-readable store. The Google manifest
   carries `clientSecretFile` and `tokenPath` as *paths*; the contents of both
   stay out. Verify by reading the generated file, not by intending it.
2. **Check the content, not just that it rendered.** Anything built with `//` or
   `lib.recursiveUpdate` can produce a perfectly valid file with the wrong values
   — an empty attrset cannot *subtract* from an inherited layer, so an entity
   declaring `{}` to opt out silently keeps everything. Dump the artifact per
   consumer and diff declared-vs-rendered (§9).

---

## 7. Shipping a script that lives in this repo

A wrapper of any size should not have its logic inside a Nix string: you lose
syntax highlighting, `bash -n`, `py_compile`, your editor, and you gain a layer of
`${}` escaping. Keep the code in a real file next to the module.

### Why you cannot just reference the checkout

```nix
# WRONG -- not reproducible
exec python3 /home/karl/NixOS/hermes/google/google_accounts.py
```

The flake checkout is **mutable**: `git pull` changes those bytes under a running
system. A runtime reference to a checkout (or to any home path) means the system's
behaviour is not determined by its derivation. `onedrive.nix` carries exactly this
warning:

> Rebuild-proof: the flake checkout is mutable on `git pull`, so nothing at
> runtime may point at a checkout or home path.

### `copyPathToStore`: content-addressed inclusion

```nix
script = pkgs.copyPathToStore ./google_accounts.py;
# …
exec ${googlePython}/bin/python3 ${script} ${verb} "$@"
```

`copyPathToStore` copies that exact file into the store, content-addressed. The
content comes from the flake's git revision, so a rebuild re-derives the right
version declaratively; editing the file changes the hash, which changes the
wrapper's store path, which is visible in the rebuild diff.

For a whole directory, plain path interpolation works the same way
(`${./skills/google-oauth}`), and `builtins.filterSource` / `lib.cleanSourceWith`
let you exclude noise so an unrelated edit does not rebuild the world.

### Bundle only what the entry point imports at runtime

`hermes/mcp/onedrive/` holds `mcp_server.py` plus `api_cli.py`, `login.py`,
`lock_test.py` — and `onedrive.nix` ships only `mcp_server.py`, because the server
does not import the others. Check before bundling: grep the entry point for sibling
imports, `importlib`, `subprocess`, and `__file__` tricks.

`hermes/google/google_accounts.py` is deliberately self-contained — stdlib plus the
three Google libraries, which come from `googlePython`, not from a sibling file.

### Two things the repo deliberately does *not* bake in

- **`google_api.py`** (the vendored google-workspace skill) is resolved at
  **runtime**, under the agent's `~/.hermes/skills/`. It is hub-managed, not a
  store path and not in this repo, so it *cannot* be baked — and vendoring a copy
  would fork from upstream silently. The script looks in three places and fails
  with a message naming all of them.
- **The OAuth token.** Minted by an interactive human consent, holds a refresh
  token, and must persist across rebuilds — so it lives in the agent's home,
  outside the store, and no deployment system can produce it.

### The companion pattern: `readFile` for a shell script

```nix
doclingHook = pkgs.writeShellApplication {
  name = "hermes-docling-pdf-hook";
  runtimeInputs = with pkgs; [ jq curl coreutils ];
  text = ''
    export DOCLING_URL=${lib.escapeShellArg cfg.doclingPdfHook.url}
    export DOCLING_TIMEOUT=${toString cfg.doclingPdfHook.timeout}
  '' + builtins.readFile ./docling-pdf-hook.sh;
};
```

A short Nix-generated prelude for the configuration, then the real script read
verbatim — so Nix `''` escaping never touches the script's own `${...}`, and the
`.sh` file stays `bash -n`-checkable with normal tooling.

---

## 8. Generating N wrappers from an attrset

The repo's strongest convention: **derive, never duplicate.** If a module already
has an attrset of entities, per-entity artifacts must be *derived from it*, so
adding an entity provisions everything automatically. A parallel hand-maintained
list that must be kept in sync is the wrong answer even when it is shorter.

Applied to executables, with `lib.mapAttrsToList`:

```nix
perAccountWrappers = lib.mapAttrsToList (name: acct:
  let
    usage = pkgs.writeText "hermes-google-${name}-usage" ''…'';
  in pkgs.writeShellApplication {
    name = "hermes-google-${name}";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ "$#" -lt 1 ] || [ "$1" = "--help" ]; then
          cat ${usage} >&2
          exit 2
      fi
      export HERMES_GOOGLE_MANIFEST=${manifest}
      exec ${googlePython}/bin/python3 ${script} api ${lib.escapeShellArg name} "$@"
    '';
  }
) accounts;
```

`mapAttrsToList : (k -> v -> a) -> attrset -> [a]` — exactly the shape
`extraPackages` wants. Declaring `google.accounts.personal` in
`hermes/users/karl.nix` makes `hermes-google-personal` exist, with its own usage
text and its own account name baked in, with **no second edit anywhere**.

Which function to reach for:

| Source → target | Function |
|---|---|
| attrset → list (packages, units) | `lib.mapAttrsToList` |
| attrset → attrset, same keys | `lib.mapAttrs` |
| attrset → attrset, renamed keys | `lib.mapAttrs'` + `lib.nameValuePair` |
| **list** → attrset | `lib.listToAttrs` + `map` |

That last row is a real trap: an option typed `listOf str` holds a list, and
`lib.mapAttrs` over it fails with `expected a set but found a list` — with the
trace pointing at the option being *defined* rather than the list being read.

### "Won't this recurse?"

Reading the *names* of an attrset to define a **different** option is ordinary and
safe; NixOS does it constantly. The real `age.secrets` fan-out in this PR:

```nix
age.secrets = lib.mapAttrs' (name: _: lib.nameValuePair "google-${name}" {
  file = ../../../secrets/google-client.age;
  owner = name; group = name; mode = "0400";
}) (lib.filterAttrs (_: a: a.google.accounts != { }) cfg.agents);
```

Recursion only bites when you define values **into** the same option you are
reading the names of. The reflex that any derivation recurses usually costs a much
better design — check which option is being written before believing it.

### Keeping the per-entity work lazy

`googleFor` returns `null` for an agent with no accounts:

```nix
googleFor = name: agent:
  if agent.google.accounts == { } then null
  else import ../../../hermes/google/wrappers.nix { … };
```

Nix is lazy, so an agent with no Google accounts never forces the wrappers and
`googlePython` stays out of that host's closure entirely. Verified: joni gets no
wrapper, no `skills.external_dirs`, and no `age.secrets."google-joni"`.

### The only evidence that a derivation works

A derived list and a hand-written list can match by coincidence. **Perturb it:**
add a throwaway entity, eval that its artifacts appeared, then revert.

```bash
nix eval --impure --expr '
let base = (builtins.getFlake "/path/to/clone").nixosConfigurations.homeserver;
    p = base.extendModules { modules = [{
      services.hermes-agents.agents.karl.google.accounts.scratch.capabilities =
        [ "mail.read" ];
    }]; };
    hm = p.config.home-manager.users.karl.services.hermes-agent;
in builtins.toJSON {
     names = map (x: x.name or "?") hm.extraPackages;
     scopes = p.config.services.hermes-agents.agents.karl.google.accounts.scratch.scopes;
   }'
```

`hermes-google-scratch` in the package list, and
`[ "…/gmail.readonly" ]` in `scopes`, is the proof. Note it reads the **downstream
consumer** (`home-manager.users.<u>.services.hermes-agent.extraPackages`), not the
option that was declared — a module that transforms a value on its way to the real
consumer makes the declared option a false negative.

---

## 9. Testing a wrapper without root

None of this needs privileges. All of it is evaluation and building; nothing is
activated.

### Build it and read it

```bash
# find the derivation (not the output path -- that may not be built yet)
cd ~/work/<clone> && git add -A      # flakes ignore untracked files
nix eval --no-write-lock-file --impure --raw --expr '
let c = (builtins.getFlake "/home/karl/work/<clone>").nixosConfigurations.homeserver.config;
    ps = c.home-manager.users.karl.services.hermes-agent.extraPackages;
    g = builtins.filter (p: builtins.match "hermes-google.*" (p.name or "") != null) ps;
in builtins.concatStringsSep "\n" (map (p: p.drvPath) g)'

# realise it -- the build log carries the shellcheck findings
nix-store --realise /nix/store/…-hermes-google-auth.drv
nix log /nix/store/…-hermes-google-auth.drv    # read them when it fails

# read the rendered script
cat /nix/store/…-hermes-google-auth/bin/hermes-google-auth
```

**Read it, do not just confirm it built.** This is where you verify §3 (did a
`${VAR}` survive?), §2 (what is on `PATH`?) and §5 (is the policy really baked in?).

If you only have a context-bearing *string* rather than a derivation, the
`"string … is not the right placeholder"` error names the `.drv` — realise that.

### `bash -n` the result

```bash
bash -n /nix/store/…/bin/hermes-google-auth && echo "syntax OK"
```

Cheap, and it catches a `${}` collision that produced valid-ish Nix output and
invalid shell.

### Run it from a scrubbed environment

The whole point of `runtimeInputs` is independence from your shell, so test it
without your shell:

```bash
mkdir -p ~/work/t3home
env -i HOME=$HOME/work/t3home TERM=dumb \
  /nix/store/…/bin/hermes-google-status
```

`env -i` clears the environment completely. A missing `runtimeInputs` entry shows
up here as `command not found` and nowhere else. Point `HOME` at a temp dir so a
script that writes to `$HOME` cannot touch the real one.

### Exercise the real failure paths

"It printed `--help`" is weak evidence. Drive the paths that only run when
something goes wrong, and make the failures *reachable* without live credentials:

- **Unreachable endpoint instead of a missing credential.** An endpoint at
  `http://127.0.0.1:1/` lets config loading succeed (the property under test) and
  then dies on the connection, so nothing is contacted.
- **A stub for the thing you cannot call.** The 403 translation was proven by
  pointing `HERMES_GOOGLE_API` at a six-line stub that prints Google's real 403
  body and exits 1. Two different subcommands selected two different remediation
  rows — which also proves the row lookup is real and not a hardcoded string.
- **A synthetic manifest with the same shape**, under a throwaway `HOME`, so the
  per-account paths point somewhere disposable.
- **Fake credentials for a real network path.** The OAuth code exchange (adapted
  prototype code, never run before) was driven with a fake client secret and a fake
  authorization code to a **structured error from Google's live token endpoint**:
  `(invalid_client) The OAuth client was not found.` Reaching that proves the whole
  path executed — secret load, `Flow` construction with the baked scopes,
  pending-session read, state check, PKCE verifier, network request — without
  completing a consent, which is a human's interactive step.

**Verify an acceptance check can actually fail before trusting it.** Run it against
the known-broken input first. A check that passes there is unfalsifiable and proves
nothing. (`setup.py --status` in the vendored skill returns before it validates
anything, and exits 0 either way.)

### Diff declared-vs-rendered, per entity

```bash
python3 -m json.tool /nix/store/…-hermes-google-accounts-karl.json
```

Then compare each account's `scopes`, `tokenPath` and `capabilities` against what
the user file declared. A merge-order or inheritance bug produces a syntactically
perfect file with the wrong content and passes every check that only asks "did it
build". For anything whose narrower scope is supposed to mean *less*, prove the
narrow case renders *less* — "it evaluates" and "the wide case looks right" are
both compatible with the bug.

### The three tiers, together

| Tier | Command | Catches |
|---|---|---|
| 1 | `nix-instantiate --parse <f>.nix` | syntax only |
| 2 | `nix eval …config.<option>` + `extendModules` perturbation | wiring, derived values, both branches of an option |
| 3 | realise + `bash -n` + run scrubbed + read the artifacts | PATH, `${}`, escaping, actual behaviour |

Tier 2 ends when it prints a `.drv` path — **`nix eval` reports one error at a
time**, so a green-looking fix only proves the *first* error is gone.

---

## 10. Pitfalls

### Forgetting `runtimeInputs`

**Symptom:** works from your shell, `command not found` from a systemd unit, a
hook, or cron.
**Why:** those get a minimal `PATH`.
**Fix:** list every external command. Builtins are free; coreutils is not.
**Catch it:** `env -i HOME=/tmp/x <wrapper>`.

### Unescaped `${}`

**Symptom:** `error: undefined variable 'HOME'` — or, worse, no error and a
build-time Nix value silently baked in where a runtime shell value was meant.
**Why:** Nix interpolates before bash sees the text (§3).
**Fix:** `''${VAR}` inside `''…''`, `\${VAR}` inside `"…"`.
**Catch it:** read the built script; a `${VAR}` that survived is one bash will
expand.

### Relying on `$HOME`

**Symptom:** files land in the wrong place, or `Permission denied`, when the same
script works interactively.
**Why:** a systemd unit, a container, or `sudo -u` may set a different `$HOME` — or
none. `set -o nounset` then aborts on a bare `$HOME`.
**Fix:** take the path as an argument or bake it in. The Google manifest carries
`hermesHome` and every `tokenPath` as absolute paths derived by Nix; `$HOME` is
used only as a last-resort fallback when resolving the vendored skill, and the
failure message names every path it tried.

### `writeShellApplication` failing the build on a shellcheck warning

**Symptom:** the rebuild fails with `SC####` on code that looks fine.
**Why:** the gate is deliberate.
**Fix:** address the finding. `excludeShellChecks` is almost always the wrong
answer — the warning is usually pointing at a real latent bug.

Three shapes that bite in practice:

- **SC2016** — prose with backticks inside `echo '…'`. Do not silence it; move the
  prose into a `writeText` store path and `cat` it (§4). That is exactly what
  happened in this PR.
- **SC2088** — `"~/"*)` in a `case`. A tilde inside quotes never expands, so a
  `~/x` path silently stays literal.
- **SC2015** — `cmd >f && mv … || { fail; }`. The `||` branch also runs when the
  `&&` branch fails, so the failure handler fires on success paths. Rewrite as an
  explicit `if ! …; then`.

### A heredoc inside a Nix `''` string

**Symptom:** the script's tail is silently swallowed as heredoc data.
**Why:** Nix strips only the *common* indentation, so an indented terminator stays
indented and never closes the heredoc.
**Fix:** `pkgs.writeText` / `builtins.toJSON` and `cat` or `install` the store path
(§6).

### Relative paths after moving a module

**Symptom:** a build error far from the edit.
**Why:** `./x` resolves against the **file**, not the repo root — so
`../../../secrets/google-client.age` in `modules/services/hermes/hermes.nix` means
something different the moment the file moves.
**Fix:** recount the levels from the file's new location, and **force the path in
an eval** — `builtins.attrNames` and reading `owner`/`mode` never force `file`, so
a weak eval succeeds whether or not the artifact exists.

### Asserting on the option you declared

**Symptom:** the eval shows the pre-transformation value and the change looks like
it silently failed; you re-add it and now there are two.
**Why:** the module transforms the value on its way to the real consumer.
**Fix:** trace where it is consumed. For this module that is
`config.home-manager.users.<u>.services.hermes-agent.extraPackages`, not
`config.services.hermes-agents.agents.<u>.extraPackages`.

### Trusting an API from memory

**Symptom:** `error: attribute 'application' missing`.
**Why:** the flake pins `nixos-unstable`, a moving target.
**Fix:** probe the pinned nixpkgs for the attribute before using it (§1).

### Dropping a name from a `let … in inherit`

**Symptom:** `error: undefined variable 'profiles'` after a hand edit.
**Why:** the file is shaped `let inherit (import ../lib.nix {…}) mcp profiles; in …`
and somebody trimmed a name the body still uses.
**Fix:** after editing such a file, check every name used in the body is still
bound — and check the sibling `users/*.nix` files, which usually carry the same
trim.

Related and important: that registry is a `let` binding and **not** a module
argument on purpose. `secrets/secrets.nix` plain-`import`s `hermes/users/*.nix`
with `pkgs = null`, and Nix's laziness is what makes those nulls safe. Turning it
into a module argument would force it eagerly and break `agenix -e`. The `skills`
registry added in this PR preserves that property: `pkgs.runCommand` is only
forced when a caller actually reads a skill path.

---

## Where to look in this repo

| Pattern | File |
|---|---|
| `writeShellApplication` + baked config + generated-per-entity | `hermes/google/wrappers.nix` |
| `writeShellScriptBin` + `copyPathToStore`, and the `pkgs.python3.application` note | `hermes/mcp/onedrive.nix` |
| `\${VAR}` reaching an MCP server through `.env` | `hermes/mcp/onedrive.nix` line 41 |
| `writeShellApplication` + `readFile` + `runtimeInputs` | `doclingHook`, `modules/services/hermes/hermes.nix` |
| `writers.writePython3` with libraries | `pruneMcpScript`, same file |
| `install -D -m 0600` from a `home.activation` entry | `hermesProfileEnv` / `hermesGoogleManifest`, same file |
| `readDir` auto-discovery registry, and why it is `let`-bound | `hermes/lib.nix` |
| plain-data table with no `pkgs`/`lib`, consumed as an option type | `hermes/google/capabilities.nix`, `hermes/google/default.nix` |
| deriving agenix rules from a host profile | `secrets/secrets.nix` |
