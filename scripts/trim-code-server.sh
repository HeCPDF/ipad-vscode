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
#   - drops argon2 (code-server's own login-page password hashing) since we
#     run with --auth none: loopback-only, single-user, no exposed surface.
#
# Usage: trim-code-server.sh <path-to-extracted-release-dir>
set -euo pipefail

RELEASE_DIR="${1:?usage: trim-code-server.sh <release-dir>}"
cd "$RELEASE_DIR"

# Everything below this line is a genuine iOS sandbox hard-wall, not a
# convenience cut. Nothing else gets removed: Copilot, MSAL, JS-Debug's
# win32 binaries, kerberos, argon2, --auth, sqlite3/parcel-watcher/spdlog
# native bindings all stay — they either work as-is (pure JS, or a native
# module that's a real cross-compile TODO, not a removal) or are simply
# unused on this platform without needing to be deleted.
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

echo "trim complete (node-pty, node_modules/.bin symlinks). remaining .node files (kept, for future cross-compile):"
find . -name "*.node"
echo "size: $(du -sh . | cut -f1)"
