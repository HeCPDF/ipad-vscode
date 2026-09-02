#!/usr/bin/env node
// Small textual fixups applied *between* certain patches in
// vscode-patches/series, run by vscode-reh-web-build.yml.
//
// Each patch in vscode-patches/ was copied from HeCPDF/code-server's own
// patches/ (see README's "switch to official vscode source" section for
// why: that fork's lib/vscode already *is* an unmodified microsoft/vscode
// checkout plus this same patch series -- the ~24 patches kept here are
// the necessary self-hosting glue (base path, open-vsx marketplace,
// telemetry endpoint, local storage, signature verification off, iOS
// worker_threads extension host, etc.), not Coder branding). code-server's
// own patch series was written to apply against ITS OWN, longer patch
// stack, which also includes a few Coder-brand-only patches we deliberately
// dropped (getting-started.diff's promo box, app-name.diff, logout.diff,
// copilot.diff). Those patches also happened to touch these same shared
// option-registration blocks (serverEnvironmentService.ts's CLI option
// list, webClientServer.ts's productConfiguration object, product.ts's
// IProductConfiguration interface) as pure context lines further down the
// stack -- dropping them shifted that context just enough for a handful of
// later patches' hunks to fail (confirmed locally: `patch -p3` against a
// fresh microsoft/vscode checkout at the pinned commit, applying the kept
// series in order -- see git history). Every failure was the same shape:
// one or two lines the dropped patches would have added, now missing from
// an anchor block another kept patch's hunk expected. This script inserts
// exactly those missing lines by unique-string anchor, in the same order
// discovered, so the build is reproducible without a human re-doing the
// same by-hand patch each time.
//
// Usage: node vscode-patch-fixups.mjs <after-patch-name> <vscode-checkout-dir>
// Called once after each of: proxy-uri, external-file-actions, display-language.

import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [, , stage, vscodeDir] = process.argv;
if (!stage || !vscodeDir) {
	console.error('usage: vscode-patch-fixups.mjs <stage> <vscode-checkout-dir>');
	process.exit(1);
}

function fixup(relPath, anchor, insert) {
	const path = join(vscodeDir, relPath);
	const text = readFileSync(path, 'utf8');
	if (text.includes(insert)) {
		console.log(`already present, skipping: ${relPath}: ${insert.trim()}`);
		return;
	}
	const idx = text.indexOf(anchor);
	if (idx === -1) {
		console.error(`::error::anchor not found in ${relPath}: ${JSON.stringify(anchor)}`);
		process.exit(1);
	}
	const insertAt = idx + anchor.length;
	const patched = text.slice(0, insertAt) + insert + text.slice(insertAt);
	writeFileSync(path, patched);
	console.log(`fixed up ${relPath} after "${anchor.trim()}"`);
}

switch (stage) {
	case 'proxy-uri':
		// proxy-uri.diff expects a logoutEndpoint line (added by the
		// dropped logout.diff) right before where it inserts
		// proxyEndpointTemplate. Anchor on updateEndpoint instead, the
		// line that's actually still there.
		fixup(
			'src/vs/server/node/webClientServer.ts',
			`updateEndpoint: !this._environmentService.args['disable-update-check'] ? rootBase + '/update/check' : undefined,`,
			`\n\t\t\tproxyEndpointTemplate: process.env.VSCODE_PROXY_URI ?? rootBase + '/proxy/{{port}}/',`
		);
		fixup(
			'src/vs/base/common/product.ts',
			`\treadonly updateEndpoint?: string`,
			`\n\treadonly proxyEndpointTemplate?: string`
		);
		break;

	case 'external-file-actions':
		// external-file-actions.diff expects to insert its two flags
		// right after disable-update-check -- true both here and in
		// code-server's own stack, so this one isn't about a dropped
		// patch; it's disable-getting-started-override (added later, by
		// display-language's stage below in our trimmed order) not
		// existing yet. Anchor on disable-update-check directly.
		fixup(
			'src/vs/server/node/serverEnvironmentService.ts',
			`\t'disable-update-check': { type: 'boolean' },`,
			`\n\t'disable-file-downloads': { type: 'boolean' },\n\t'disable-file-uploads': { type: 'boolean' },`
		);
		fixup(
			'src/vs/server/node/serverEnvironmentService.ts',
			`\t'disable-update-check'?: boolean;`,
			`\n\t'disable-file-downloads'?: boolean;\n\t'disable-file-uploads'?: boolean;`
		);
		break;

	case 'display-language':
		// display-language.diff expects disable-getting-started-override
		// (added by the dropped getting-started.diff) as its anchor.
		// Anchor on disable-file-uploads instead, the line that's
		// actually last in this block now.
		fixup(
			'src/vs/server/node/serverEnvironmentService.ts',
			`\t'disable-file-uploads': { type: 'boolean' },`,
			`\n\t'locale': { type: 'string' },`
		);
		fixup(
			'src/vs/server/node/serverEnvironmentService.ts',
			`\t'disable-file-uploads'?: boolean;`,
			`\n\t'locale'?: string`
		);
		break;

	default:
		console.error(`::error::unknown fixup stage: ${stage}`);
		process.exit(1);
}
