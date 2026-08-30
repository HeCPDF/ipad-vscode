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

# Extensions we don't bundle (bring their own incompatible native modules).
rm -rf lib/vscode/extensions/copilot
rm -f  lib/vscode/extensions/microsoft-authentication/dist/msal-node-runtime.node
rm -f  lib/vscode/extensions/ms-vscode.js-debug/src/win32-app-container-tokens*.node
rm -rf lib/vscode/node_modules/@github

# Core native modules with no iOS-compatible build (yet).
rm -rf lib/vscode/node_modules/kerberos
rm -rf lib/vscode/node_modules/node-pty
rm -rf lib/vscode/node_modules/@vscode/native-watchdog
rm -rf lib/vscode/node_modules/@vscode/deviceid
rm -f  lib/vscode/node_modules/@parcel/watcher/build/Release/watcher.node
rm -f  lib/vscode/node_modules/@vscode/spdlog/build/Release/spdlog.node
rm -f  lib/vscode/node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node

# code-server's own auth hashing — unused with --auth none.
rm -rf node_modules/argon2

echo "trim complete. remaining .node files (should be empty):"
find . -name "*.node"
echo "size: $(du -sh . | cut -f1)"
