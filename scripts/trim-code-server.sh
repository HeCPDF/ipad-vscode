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
# Replace the Unicode property classes with ASCII-only equivalents
# everywhere they appear in the fetched payload (multiple build formats
# may bundle their own copy). This means a route parameter name with a
# non-ASCII character (e.g. `/users/:文件`) would no longer validate --
# an exceedingly rare thing to name a route parameter, and code-server's
# own routes don't do this, so this is a real but practically-inert
# functionality cut, not a silent correctness risk.
# Substitution done via node -e rather than sed: the exact number of
# backslashes sed needs in its own pattern language to match a literal
# `\p{ID_Start}` is easy to get subtly wrong (and was, in an earlier
# revision of this script -- verified locally: it silently left a
# dangling backslash behind, `[$_\a-zA-Z]`, which doesn't even parse as a
# valid regex). Plain JS string replacement has no such ambiguity.
node -e "
  const fs = require('fs');
  const path = require('path');
  function walk(dir) {
    for (const name of fs.readdirSync(dir)) {
      const full = path.join(dir, name);
      const stat = fs.lstatSync(full);
      if (stat.isDirectory()) walk(full);
      else if (stat.isFile()) {
        const text = fs.readFileSync(full, 'utf8');
        if (text.includes('\\\\p{ID_Start}') || text.includes('\\\\p{ID_Continue}')) {
          const patched = text
            .split('\\\\p{ID_Start}').join('a-zA-Z')
            .split('\\\\p{ID_Continue}').join('0-9a-zA-Z_');
          fs.writeFileSync(full, patched);
          console.log('patched \\\\p{ID_Start}/\\\\p{ID_Continue} in ' + full);
        }
      }
    }
  }
  walk('.');
"

echo "trim complete (node-pty, node_modules/.bin symlinks). remaining .node files (kept, for future cross-compile):"
find . -name "*.node"
echo "size: $(du -sh . | cut -f1)"
