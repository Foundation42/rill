// The seam: this extension against the REAL `rill` binary.
//
// Every other suite here runs against `test/stubs/rill.mjs`, which is a
// stand-in written to behave badly in one named way per gate. That is the
// right shape for the client's guards — you cannot ask a real binary to eat
// your comments on demand — but it means nothing in this repo had ever
// checked that the binary and the client agree about anything at all. A stub
// answers whatever it was told to answer, including a subcommand the real
// `rill` has never heard of.
//
// So: X1..X5 run the artifact `zig build` produces.
//
// **X1 is the one to read.** rill's printer landed on 2026-09-09 and the 47
// `.rill` programs Christian has were normalised to its canon the same day.
// This feeds every one of them through `rill fmt` and asserts the bytes come
// back unchanged. That is the single strongest statement that format-on-save
// is safe to switch on: not "the formatter is idempotent" (it can be
// idempotent about the wrong thing) but "his files do not move".
//
// THE SKIP IS LOUD. A silent skip is a gate that watches nothing, and this
// suite is skippable by construction — the binary is built by another repo's
// build system. If it is not there, every gate says so by name and says how
// to get it.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile, readdir, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(here, '..');
// RILL_ROOT from the environment first: `test/mutate.mjs` runs this suite
// from a COPY of the tree one directory deeper, where the relative walk up
// lands in `editors/` and finds neither the binary nor the corpus.
const RILL_ROOT = process.env.RILL_ROOT || path.resolve(EXT_ROOT, '..', '..');
const SIBLINGS = process.env.RILL_SIBLINGS || path.resolve(RILL_ROOT, '..');

const cli = require(path.join(EXT_ROOT, 'src', 'rillcli.js'));
const manifest = require(path.join(EXT_ROOT, 'package.json'));

/** The manifest's own defaults, so a gate cannot pass against args nobody ships. */
const props = manifest.contributes.configuration.properties;
const DEFAULT_FMT_ARGS = props['rill.format.args'].default;
const DEFAULT_CHECK_ARGS = props['rill.diagnostics.args'].default;

/**
 * Where the binary is.
 *
 * `zig build` in the rill checkout puts it at `zig-out/bin/rill`; RILL_BINARY
 * overrides for a machine that installed it somewhere else. Deliberately NOT
 * a bare `rill` off PATH: a gate that silently measured whatever version
 * happened to be installed would be measuring the wrong tree.
 */
const BINARY = process.env.RILL_BINARY || path.join(RILL_ROOT, 'zig-out', 'bin', 'rill');
const HAVE = existsSync(BINARY);

const SKIP = HAVE ? false : `no rill binary at ${BINARY} — run \`zig build\` in ${RILL_ROOT}, or set RILL_BINARY`;
if (!HAVE) {
  // Loud, on stderr, once — `node --test` prints a skip reason in its own
  // report but a person reading a green scroll should not have to find it.
  process.stderr.write(`\n  !! e2e gates X1..X5 SKIPPED: ${SKIP}\n\n`);
}

/** The 47: rill's own tree plus the two siblings, minus the three noise dirs. */
async function corpus() {
  const roots = [
    RILL_ROOT,
    path.join(SIBLINGS, 'spindrift'),
    path.join(SIBLINGS, 'matryoshka'),
  ];
  const skip = new Set(['.zig-cache', 'scratchpad', 'editors', '.git', 'node_modules', 'zig-out']);
  const found = [];
  async function walk(dir) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (skip.has(e.name)) continue;
        await walk(path.join(dir, e.name));
      } else if (e.name.endsWith('.rill')) {
        found.push(path.join(dir, e.name));
      }
    }
  }
  for (const r of roots) await walk(r);
  found.sort();
  return found;
}

// ---------------------------------------------------------------------------

test('X1: `rill fmt` is a NO-OP over all 47 corpus files', { skip: SKIP }, async () => {
  const files = await corpus();
  // The count is asserted, not just the sweep. A walk that found four files
  // because a sibling moved would otherwise report 4/4 and read as green —
  // the vacuous pass that `-Dtest-filter` warns about in rill's build.zig.
  assert.equal(files.length, 47, `found ${files.length} .rill files:\n${files.join('\n')}`);

  const moved = [];
  for (const file of files) {
    const source = await readFile(file, 'utf8');
    // `--host-row` because 21 of these are spray kernels: rill core does not
    // know `spawn` or `near` and must not, so without the stubs a fifth of
    // the corpus exits 65 and this gate would be measuring 26 files.
    const res = await cli.formatSource(BINARY, ['fmt', '--host-row', '-'], source, { timeoutMs: 20000 });
    if (res.status !== 'unchanged') {
      moved.push(`${path.relative(SIBLINGS, file)} → ${res.status}${res.detail ? `: ${res.detail}` : ''}`);
    }
  }
  assert.deepEqual(moved, [], `${moved.length} of ${files.length} files are not fixed points`);
});
// MUTATION: this gate stands over the BINARY, so its mutations are the F
// series in `rill/src/cli.zig` — F1 (a banner on stdout), F2 (fmt echoes its
// input), F3 (comments dropped). Each was run there and each went red. What
// is mutable HERE is the sweep itself: change `formatSource`'s status test to
// `res.status === 'missing'` and the gate passes on a machine with no binary,
// which is the vacuous shape this file exists to avoid.

test('X2: the probe survives the real binary — the comment comes back', { skip: SKIP }, async () => {
  // The extension formats NOTHING until this answers. `probeFormat` sends a
  // comment-only program and refuses the binary unless the comment is in the
  // reply, because a formatter that swallows prose would delete four-fifths
  // of `roaches.rill` on the first save.
  const probe = await cli.probeFormat(BINARY, DEFAULT_FMT_ARGS);
  assert.equal(probe.ok, true, `probe failed: ${probe.reason} ${probe.detail || ''}`);
});

test('X3: the seam — the binary codes it, the client downgrades it', { skip: SKIP }, async () => {
  // End to end, and the whole reason `Diag` grew a `code`: a spray kernel
  // checked WITHOUT the host's vocabulary must come back as a warning, not as
  // a red file. Three parties have to agree — the parser's refusal site, the
  // JSON, and `makeDiagnostics` — and until now nothing ran all three.
  const fake = require(path.join(here, 'fake-vscode.cjs'));
  fake.install();
  fake.reset();
  delete require.cache[require.resolve(path.join(EXT_ROOT, 'src', 'extension.js'))];
  const ext = require(path.join(EXT_ROOT, 'src', 'extension.js'));

  const kernel = [
    '// a spray kernel: row words at the top level',
    'near 0.5 as crowd',
    'crowd | write row.u3',
    '',
  ].join('\n');

  const bare = await cli.checkSource(BINARY, DEFAULT_CHECK_ARGS, kernel);
  assert.equal(bare.status, 'diagnostics');
  assert.equal(bare.diagnostics.length, 1);
  assert.equal(bare.diagnostics[0].code, 'unknown_operator');
  assert.equal(bare.diagnostics[0].line, 2, 'and it points at the row word, 1-based');

  const cfg = fake.vscode.workspace.getConfiguration();
  const made = ext.makeDiagnostics(fake.document(kernel), bare.diagnostics, cfg);
  assert.equal(made.length, 1);
  assert.equal(made[0].severity, fake.vscode.DiagnosticSeverity.Warning,
    'the SHIPPED default must downgrade it, or a kernel opens red');

  // …and with the host's words named, the same file is clean. Both halves,
  // or a binary that ignored `--host-row` would pass the first one.
  const withHost = await cli.checkSource(BINARY, ['check', '--json', '--host-row', '-'], kernel);
  assert.equal(withHost.status, 'ok');
  assert.deepEqual(withHost.diagnostics, []);
});

test('X4: the manifest ships args the real binary answers to', { skip: SKIP }, async () => {
  // THE mutation this file was written for. `rill.format.args` and
  // `rill.diagnostics.args` are defaults in `package.json`; nothing else in
  // the suite runs them, because the stub ignores its arguments entirely and
  // answers by mode. A typo in either — `format` for `fmt`, a dropped
  // `--json` — ships as a feature that is silently off on every machine, and
  // reports as EX_USAGE, which the extension is designed to say once and then
  // stop mentioning.
  const fmt = await cli.formatSource(BINARY, DEFAULT_FMT_ARGS, 'plane.a | write plane.b\n');
  assert.notEqual(fmt.status, 'unsupported', `${DEFAULT_FMT_ARGS.join(' ')}: ${fmt.detail || ''}`);
  assert.equal(fmt.status, 'unchanged');

  const chk = await cli.checkSource(BINARY, DEFAULT_CHECK_ARGS, 'plane.a | write plane.b\n');
  assert.notEqual(chk.status, 'unsupported', `${DEFAULT_CHECK_ARGS.join(' ')}: ${chk.detail || ''}`);
  assert.equal(chk.status, 'ok');
});
// MUTATION: in package.json, set `rill.format.args`'s default to
// `["format", "-"]`. The real binary exits 64, `formatSource` reports
// 'unsupported', and this goes red — while every stub-backed gate stays green,
// because the stub never looked at its arguments.

test('X5: a file that does not parse is left alone — 65, and no text', { skip: SKIP }, async () => {
  // The client's C5 asserts this against a stub that was TOLD to exit 65.
  // This asserts the real binary chooses 65 for a real syntax error, and that
  // nothing came back on stdout with it — a formatter that emitted what it
  // managed before giving up would hand `formatSource` a truncated program
  // and exit 0, and the provider replaces the whole document with it.
  const res = await cli.formatSource(BINARY, ['fmt', '-'], 'plane.a | | write plane.b\n');
  assert.equal(res.status, 'parse-error');
  assert.equal(res.text, undefined);

  // And the same file through `check` is one readable diagnostic, coded
  // `parse` — not `unknown_operator`, which the client would downgrade to a
  // warning and let a genuine syntax error through as a hint.
  const chk = await cli.checkSource(BINARY, DEFAULT_CHECK_ARGS, 'plane.a | | write plane.b\n');
  assert.equal(chk.status, 'diagnostics');
  assert.equal(chk.diagnostics[0].code, 'parse');
});
