#!/usr/bin/env bash
# Strips a freshly-built vscode-reh-web-linux-x64 tree down to what can run
# inside nodejs-mobile's embedded Node runtime on iOS, and applies the same
# nodejs-mobile/iOS runtime-capability fixups scripts/trim-code-server.sh
# already found and fixed for the code-server-fork build (that script's own
# comments have the full evidence trail: real crashes captured via
# NodeRuntimeController's stdio log, fixed one at a time). This is a sibling
# script, not a copy for its own sake: this build has no code-server CLI
# wrapper (out/node/entry.js) or argon2 dependency at all -- it runs
# vscode's own native server-main.js entry directly -- so the argon2 stub
# doesn't apply, and the crypto-shim insertion targets server-main.js
# instead.
#
# Usage: trim-vscode-reh-web.sh <path-to-vscode-reh-web-linux-x64-dir>
set -euo pipefail

RELEASE_DIR="${1:?usage: trim-vscode-reh-web.sh <release-dir>}"
cd "$RELEASE_DIR"

# Same iOS sandbox hard-wall as trim-code-server.sh: no real kernel pty
# device (posix_openpt/`/dev/ptmx`) available to a sideloaded, non-jailbroken
# app, so node-pty can never work here regardless of build target.
find . -type d -name node-pty -exec rm -rf {} +

# Same Windows IPA-repackaging-tool symlink issue as trim-code-server.sh:
# node_modules/.bin/* are dev-tool symlinks never invoked by server-main.js
# at runtime.
find . -type d -name .bin -exec rm -rf {} +

# Same --with-intl=none capability gate as trim-code-server.sh: nodejs-mobile's
# iOS build has no \p{...} Unicode-property-escape regex support at all, so
# every occurrence (path-to-regexp's route params, vscode's own path/route
# validation, wherever else the same JS payload turns up in this build)
# needs the same ASCII-equivalent substitution, not just the ones already
# known to crash in the code-server build -- the two builds share almost
# all of the same node_modules and much of the same vscode source.
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

# Same import.meta.dirname (Node 20.11/21.2+) gap as trim-code-server.sh --
# nodejs-mobile's embedded Node predates it, so the bare property access
# silently evaluates to undefined instead of throwing, surfacing later as a
# "path argument must be of type string" crash wherever the result feeds
# path.join().
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

# Same missing-global-crypto gap as trim-code-server.sh (Node <19 has no
# bare `crypto` global; only require('crypto').webcrypto). There, the shim
# was prepended to code-server's own CLI wrapper (out/node/entry.js), a
# CommonJS file, so a bare require() call worked. This build has no such
# wrapper -- NodeRuntimeController loads vscode's own native server entry
# point directly, found by name rather than a hardcoded path since the
# exact output layout is being confirmed for the first time by this same
# CI run -- and that entry point's own package.json declares
# "type": "module" (vscode's reh-web build is ESM), so a CommonJS
# require() call throws "ReferenceError: require is not defined in ES
# module scope" as the very first line ever executed, before the server
# gets anywhere near binding to a port. Confirmed via a real captured
# node-stdio.log (not guessed), the first-ever Simulator run of this
# integration. Fixed with a dynamic import() instead -- valid at the top
# of an ES module via top-level await, unlike require(), and functionally
# equivalent to trim-code-server.sh's require('crypto').webcrypto.
ENTRY_JS="$(find . -maxdepth 3 -name 'server-main.js' | sort | head -1)"
if [ -n "$ENTRY_JS" ] && [ -f "$ENTRY_JS" ]; then
  if head -n1 "$ENTRY_JS" | grep -q "^#!"; then
    { head -n1 "$ENTRY_JS"; echo 'if(typeof globalThis.crypto==="undefined"){globalThis.crypto=(await import("node:crypto")).webcrypto;}'; tail -n +2 "$ENTRY_JS"; } > "$ENTRY_JS.tmp"
  else
    { echo 'if(typeof globalThis.crypto==="undefined"){globalThis.crypto=(await import("node:crypto")).webcrypto;}'; cat "$ENTRY_JS"; } > "$ENTRY_JS.tmp"
  fi
  mv "$ENTRY_JS.tmp" "$ENTRY_JS"
  echo "inserted ESM-compatible globalThis.crypto shim into $ENTRY_JS"
else
  echo "::error::no server-main.js found under $RELEASE_DIR -- entry point name assumption is wrong, update this script"
  exit 1
fi

echo "trim complete. remaining .node files (kept, for future cross-compile):"
find . -name "*.node"
echo "size: $(du -sh . | cut -f1)"
