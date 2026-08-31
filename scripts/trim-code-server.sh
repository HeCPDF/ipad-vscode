#!/usr/bin/env bash
# Strips code-server's build output down to what can plausibly run inside
# the iOS Network Extension's embedded Node runtime:
#   - drops bundled extensions we don't preset (Copilot etc. bring their own
#     linux-x64 native binaries and are out of scope for the "limited preset
#     extensions" plan)
#   - drops native (.node) modules that only have linux-x64/darwin/win32
#     prebuilds, since none of them will dlopen on iOS regardless of CPU
#     architecture (different Mach-O platform tag, different Node ABI from
#     nodejs-mobile's own libnode build). Each one either has no iOS-side
#     equivalent needed (kerberos, native-watchdog, deviceid, node-pty — see
#     README for why node-pty specifically can't work on iOS at all) or is a
#     later cross-compile task (@vscode/sqlite3, @parcel/watcher, spdlog).
#   - stubs out argon2 (code-server's own login-page password hashing).
#     `require('argon2')` happens eagerly at module load somewhere in
#     code-server's startup chain, unconditionally, regardless of --auth
#     mode — confirmed by a real crash on first boot under the app-process
#     architecture (see git history), not assumed: "Error: No native build
#     was found for platform=ios arch=arm64 ...". Deleting the package
#     outright would just change that to "Cannot find module 'argon2'",
#     still fatal. A stub that throws only if actually *called* is safe
#     because --auth none means the login flow, its only real consumer,
#     never runs.
#
# Usage: trim-code-server.sh <path-to-extracted-release-dir>
set -euo pipefail

RELEASE_DIR="${1:?usage: trim-code-server.sh <release-dir>}"
cd "$RELEASE_DIR"

# Everything below this line is a genuine iOS sandbox hard-wall, not a
# convenience cut. Nothing else gets removed: Copilot, MSAL, JS-Debug's
# win32 binaries, kerberos, --auth, sqlite3/parcel-watcher/spdlog native
# bindings all stay — they either work as-is (pure JS, or a native module
# that's a real cross-compile TODO, not a removal) or are simply unused on
# this platform without needing to be deleted.
#
# node-pty needs a real kernel pty (posix_openpt / /dev/ptmx). Sideloaded,
# non-jailbroken iOS denies that device-node access at the sandbox-profile
# level, same as it denies fork()/posix_spawn() for arbitrary children —
# this is unrelated to JIT, signing, or the multi-extension-process IPC
# trick used to route around cp.fork() for the extension host (see
# vscode/src/vs/server/node/extensionHostConnection.ts and the
# ExtensionHostRuntime target). That trick gets you another *process*;
# it does not get you a real pty device. There is no known workaround for
# this specific one short of a full jailbreak, which is out of scope.
rm -rf lib/vscode/node_modules/node-pty

# See the header comment: argon2's native binding cannot dlopen on iOS
# (linux-x64-only prebuild, wrong Mach-O platform / Node ABI), and it's
# require()'d eagerly enough during code-server's own startup that
# --auth none doesn't prevent the crash on its own. Stub every entry
# point the package's own package.json declares (covers both the CJS
# "main" and any "exports" map, whatever this release actually ships)
# with plain no-op/rejecting stub functions — safe here since nothing
# calls them with --auth none, and loud (a rejected Promise) instead of
# silently wrong if that assumption is ever violated. A throwing Proxy
# was tried first and itself crashed startup: TypeScript's __importStar
# interop helper checks `mod.__esModule` before anything else, which hit
# the Proxy's `get` trap immediately. A plain object sidesteps every such
# introspection edge case (property enumeration, hasOwnProperty checks,
# destructuring) since it behaves exactly like any real module's exports.
for argon2_pkg in node_modules/argon2 lib/vscode/node_modules/argon2; do
  if [ -d "$argon2_pkg" ]; then
    entries=$(node -e "
      const pkg = require('./$argon2_pkg/package.json');
      const files = new Set();
      if (typeof pkg.main === 'string') files.add(pkg.main);
      const collectExports = (v) => {
        if (typeof v === 'string') files.add(v);
        else if (v && typeof v === 'object') Object.values(v).forEach(collectExports);
      };
      collectExports(pkg.exports);
      console.log([...files].join('\n'));
    ")
    for entry in $entries; do
      cat > "$argon2_pkg/$entry" <<'STUB'
function unavailable() {
  return Promise.reject(new Error(
    "argon2 stub: real password hashing is unavailable on iOS (runs with --auth none only) -- see scripts/trim-code-server.sh"
  ));
}
module.exports = {
  hash: unavailable,
  verify: unavailable,
  needsRehash: () => false,
  argon2i: 0,
  argon2d: 1,
  argon2id: 2,
  limits: {},
};
STUB
    done
    echo "stubbed argon2 entry points in $argon2_pkg: $entries"
  fi
done

# Unrelated to the iOS sandbox: npm's node_modules/.bin/* entries are
# symlinks (pointing at the real script inside each package's own
# directory), and the macOS CI runner's `zip -y` preserves them as real
# POSIX symlinks with Unix mode bits set in the archive's external file
# attributes. Several Windows-based IPA signing/repackaging tools can't
# parse that and fail with an opaque "Failed to read: <name>" error on the
# first one they hit (reported against a real IPA build: "node-gyp-build").
# These are pure CLI dev-tool shortcuts (js-yaml, semver, cross-env, etc.)
# that code-server's own server process never invokes at runtime — it runs
# via `node out/node/entry.js` and requires its dependencies directly, not
# through .bin/* — so removing them is a zero-functionality-loss fix for
# Windows tooling compatibility, not a feature cut.
find . -type d -name .bin -exec rm -rf {} +

# nodejs-mobile's iOS build compiles with --with-intl=none (no V8 i18n
# support at all), which also disables Unicode property escapes (\p{...})
# in regular expressions -- not just locale-aware formatting; that's a
# compile-time capability gate, unrelated to how much locale data is
# bundled. path-to-regexp (used by code-server's own HTTP routing, via
# `router`/`express`) uses \p{ID_Start}/\p{ID_Continue} to validate
# identifier characters in route parameter names (e.g. the `id` in
# `/users/:id`) -- confirmed as a real startup crash, not assumed
# ("Invalid regular expression: ... Invalid property name in character
# class"). Switching nodejs-mobile to full/small-icu was tried and
# reverted: it exposed a separate, real bug in nodejs-mobile's own build
# system (a build-time host tool gets cross-compiled as an iOS binary
# instead of one that can run on the Mac doing the building) -- a deeper
# fix worth doing later, tracked but not blocking this one.
#
# Replace Unicode property escapes with ASCII-only equivalents everywhere
# they appear in the fetched payload (multiple build formats may bundle
# their own copy). This started out matching only \p{ID_Start}/
# \p{ID_Continue} (path-to-regexp's route-parameter validation), but
# --with-intl=none rejects the \p{...} *syntax* itself at regex-compile
# time regardless of which property name is inside the braces -- it's a
# parser-level capability gate, not specific to those two names. Confirmed
# as a second, separate real crash via NodeRuntimeController's captured
# stdio log, after the ID_Start/ID_Continue fix already landed: vscode's
# own server bundle (lib/vscode/out/server-main.js, loaded by
# code-server's loadVSCode()) uses \p{L} (invoked from
# ensureVSCodeLoaded/CodeServerRouteWrapper) in a route/path validation
# regex, unrelated to path-to-regexp -- "Invalid regular expression: ...
# Invalid property name in character class" again, different file,
# different property name. Matching every \p{...}/\P{...} occurrence
# generically, not just those two known ones, closes this whole class of
# crash instead of patching one more instance at a time as each is
# separately discovered by hitting it at runtime.
# This means a route/identifier containing a non-ASCII character no
# longer validates via these specific checks -- rare in practice, and
# code-server's own routes don't do this, so it's a real but
# practically-inert functionality cut, not a silent correctness risk.
# Substitution done via node -e string scanning rather than sed or a
# regex: the exact number of backslashes sed needs in its own pattern
# language to match a literal `\p{...}` is easy to get subtly wrong (and
# was, in an earlier revision of this script -- verified locally: it
# silently left a dangling backslash behind, `[$_\a-zA-Z]`, which doesn't
# even parse as a valid regex), and a JS regex literal embedded in this
# same bash double-quoted string would need yet another layer of
# backslash-counting on top of that. Plain indexOf/slice scanning for the
# literal `\p{` marker has no such ambiguity in either layer.
node -e "
  const fs = require('fs');
  const path = require('path');
  const REPLACEMENTS = {
    ID_Start: 'a-zA-Z',
    ID_Continue: '0-9a-zA-Z_',
    L: 'a-zA-Z',
    Lu: 'A-Z',
    Ll: 'a-z',
    N: '0-9',
    Nd: '0-9',
    Alphabetic: 'a-zA-Z',
    Alpha: 'a-zA-Z',
  };
  const FALLBACK = 'a-zA-Z0-9_';
  const MARKER = '\\\\p{';
  function patch(text) {
    let out = '';
    let i = 0;
    let changed = false;
    while (true) {
      const start = text.indexOf(MARKER, i);
      if (start === -1) { out += text.slice(i); break; }
      const end = text.indexOf('}', start);
      if (end === -1) { out += text.slice(i); break; }
      const propName = text.slice(start + MARKER.length, end);
      out += text.slice(i, start);
      out += (propName in REPLACEMENTS) ? REPLACEMENTS[propName] : FALLBACK;
      i = end + 1;
      changed = true;
    }
    return changed ? out : null;
  }
  function walk(dir) {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const stat = fs.lstatSync(full);
      if (stat.isDirectory()) walk(full);
      else if (stat.isFile()) {
        const patched = patch(fs.readFileSync(full, 'utf8'));
        if (patched !== null) {
          fs.writeFileSync(full, patched);
          console.log('patched unicode property escapes in ' + full);
        }
      }
    }
  }
  walk('.');
"

# vscode's own server bundle (lib/vscode/out/server-main.js) computes its
# NLS (locale) metadata directory as `import.meta.dirname` -- an ESM
# property added in Node 20.11/21.2. nodejs-mobile's embedded Node
# predates that, so the property access silently evaluates to `undefined`
# (an unknown property on an object literal, not a syntax/parse error --
# unlike the \p{...} regex crashes above, this one only surfaces at
# runtime). Confirmed as a real crash via NodeRuntimeController's
# captured stdio log, one step further into startup than the \p{L} fix
# above got: "The \"path\" argument must be of type string. Received
# type undefined", thrown from server-main.js's own bundled path.join()
# polyfill, called as `join(nlsMetadataPath, "nls.messages.json")` with
# nlsMetadataPath === undefined.
#
# Replace `import.meta.dirname` with `new URL(".",import.meta.url).pathname`
# everywhere it appears -- the standard, long-supported ESM way to get a
# module's own directory, computing the same value `import.meta.dirname`
# would (modulo a trailing slash, which path.join() normalizes away; this
# is only ever used to build a path via join(), never compared as a bare
# string, so that difference doesn't matter here). `import.meta.url` is
# core ESM, not a new-Node-version feature, so this works regardless of
# which Node version is actually embedded.
node -e "
  const fs = require('fs');
  const path = require('path');
  const FROM = 'import.meta.dirname';
  const TO = 'new URL(\".\",import.meta.url).pathname';
  function walk(dir) {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const stat = fs.lstatSync(full);
      if (stat.isDirectory()) walk(full);
      else if (stat.isFile()) {
        const text = fs.readFileSync(full, 'utf8');
        if (text.includes(FROM)) {
          fs.writeFileSync(full, text.split(FROM).join(TO));
          console.log('patched import.meta.dirname in ' + full);
        }
      }
    }
  }
  walk('.');
"

# Fourth crash in the same debugging session, one step further into
# startup than the import.meta.dirname fix: after that fix, node-stdio.log
# showed "Extension host agent listening on 8000" -- real progress, past
# NLS loading entirely -- then a new one: "CodeServerRouteWrapper: crypto
# is not defined ReferenceError: crypto is not defined", thrown from
# server-main.js while handling an actual incoming connection (Array.find
# inside a request/agent-handshake handler).
#
# Node exposes the Web Crypto API as a bare global `crypto` (no require()
# needed) only since v19; before that it's available exclusively via
# require("crypto").webcrypto (stable since ~v16). This whole debugging
# session's pattern -- import.meta.dirname (20.11/21.2), \p{...} regex
# support tied to --with-intl, etc. -- points at nodejs-mobile embedding
# something around Node 18: old enough to lack the global, new enough
# that require("crypto").webcrypto genuinely exists (confirmed present in
# the sandbox's own Node here, and it's been in Node far longer than the
# auto-global convenience has).
#
# Fix at the true process entry point rather than searching for every
# bare `crypto` reference in a multi-megabyte minified bundle (unlike the
# two patches above, "crypto" is far too common a substring/identifier to
# safely blanket-replace -- it would just as easily hit a local variable
# or an already-correct require("crypto") call). Prepend a global-crypto
# shim to the compiled out/node/entry.js -- the literal file node_start()
# loads (NodeRuntimeController.swift) -- so it runs before every other
# require() in the process, CommonJS or dynamically-imported ESM alike
# (globalThis is shared process-wide regardless of module system), and is
# a no-op on any future build where the global already exists natively.
ENTRY_JS="out/node/entry.js"
if [ -f "$ENTRY_JS" ]; then
  # code-server's own build-code-server.sh already prepends a
  # #!/usr/bin/env node shebang as line 1 if one isn't already there.
  # Node only recognizes/strips a shebang on the file's literal first
  # line -- inserting our shim above it would push the shebang to line 2,
  # where Node would instead try to parse "#!/usr/bin/env node" as
  # JavaScript and fail immediately on the leading `#`. Insert after the
  # shebang if present, otherwise at the very top.
  if head -n1 "$ENTRY_JS" | grep -q "^#!"; then
    { head -n1 "$ENTRY_JS"; echo 'if(typeof globalThis.crypto==="undefined"){globalThis.crypto=require("crypto").webcrypto;}'; tail -n +2 "$ENTRY_JS"; } > "$ENTRY_JS.tmp"
  else
    { echo 'if(typeof globalThis.crypto==="undefined"){globalThis.crypto=require("crypto").webcrypto;}'; cat "$ENTRY_JS"; } > "$ENTRY_JS.tmp"
  fi
  mv "$ENTRY_JS.tmp" "$ENTRY_JS"
  echo "inserted globalThis.crypto shim into $ENTRY_JS"
else
  echo "WARNING: $ENTRY_JS not found, cannot insert globalThis.crypto shim" >&2
fi

echo "trim complete (node-pty, node_modules/.bin symlinks). remaining .node files (kept, for future cross-compile):"
find . -name "*.node"
echo "size: $(du -sh . | cut -f1)"
