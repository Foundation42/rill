// The client's gates.
//
// The one that matters is C1: a missing binary must leave the document
// alone. rill ships no `fmt` today, so on the day this is installed EVERY
// format is that case — the fallback is not an edge, it is the main path.
//
// Everything under test here is in `src/rillcli.js` and `src/symbols.js`,
// which do not import `vscode`. That split is the reason these gates can run
// at all: a decision that only executes inside an editor is a decision nobody
// can gate.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(here, '..');

const cli = require(path.join(EXT_ROOT, 'src', 'rillcli.js'));
const { outline } = require(path.join(EXT_ROOT, 'src', 'symbols.js'));

const NODE = process.execPath;
const STUB = path.join(here, 'stubs', 'rill.mjs');
const stub = (mode) => [STUB, mode, 'fmt', '-'];

const SOURCE = [
  '// the room',
  'using plane.drift.@self.k as :k',
  '',
  '  near :k.tight | write row.u3',
  '',
].join('\n');

// ---------------------------------------------------------------------------
// C1 — THE ONE THAT PROTECTS HIS FILES.
// ---------------------------------------------------------------------------

test('C1: binary missing → document unchanged', async () => {
  const res = await cli.formatSource('/nonexistent/rill-does-not-exist', ['fmt', '-'], SOURCE);
  assert.equal(res.status, 'missing');
  assert.equal(res.text, undefined, 'nothing to write is the whole point');
});
// MUTATION: replace guard 1 in formatSource with
//   `if (res.spawnError) return { status: 'formatted', text: res.stdout };`
// — the naive shape, where stdout is trusted because the call "returned".
// The status is then 'formatted' with an empty text, the provider replaces
// the whole document with nothing, and this goes red on both assertions.

test('C1b: a missing binary is missing, not "unsupported"', async () => {
  // The two get different sentences in the editor, and telling him the binary
  // does not understand `fmt` when the binary is not there would send him to
  // fix the wrong thing.
  const probe = await cli.probeFormat('/nonexistent/rill-does-not-exist', ['fmt', '-']);
  assert.equal(probe.ok, false);
  assert.equal(probe.reason, 'missing');
});

// ---------------------------------------------------------------------------
// C2..C6 — the other four ways a formatter can hurt a file.
// ---------------------------------------------------------------------------

test('C2: exit 0 and nothing back → refused', async () => {
  const res = await cli.formatSource(NODE, stub('empty'), SOURCE);
  assert.equal(res.status, 'refused');
  assert.equal(res.text, undefined);
});
// MUTATION: delete guard 3 (the `stdout.trim().length === 0` branch). The
// status becomes 'formatted' with an empty text and the file is emptied on
// the next save.

test('C3: comments dropped → refused, and LOUD', async () => {
  const res = await cli.formatSource(NODE, stub('strip-comments'), SOURCE);
  assert.equal(res.status, 'suspect');
  assert.equal(res.text, undefined);
  assert.match(res.detail, /comment lines/);
});
// MUTATION: change guard 4's test from `after < before` to `after < 0`. The
// prose-eating formatter is believed, `roaches.rill` comes back as eleven
// lines of code, and this goes red.

test('C4: a binary that does not know the subcommand → unsupported', async () => {
  const res = await cli.formatSource(NODE, stub('usage'), SOURCE);
  assert.equal(res.status, 'unsupported');
  assert.equal(res.text, undefined);
});
// MUTATION: delete the EX_USAGE branch. It falls to 'refused', which the
// extension reports as a failure rather than as "off until rill ships it" —
// a wall of errors on a toolchain that is simply not there yet.

test('C5: a file that does not parse → parse-error, and no message', async () => {
  const res = await cli.formatSource(NODE, stub('dataerr'), SOURCE);
  assert.equal(res.status, 'parse-error');
  assert.equal(res.text, undefined);
});
// MUTATION: delete the EX_DATAERR branch. Every format of a half-typed file
// pops "formatting unavailable", which is both wrong and the noise the brief
// rules out — the squiggle already said it, in the right place.

test('C6: already formatted → no edit at all', async () => {
  const res = await cli.formatSource(NODE, stub('echo'), SOURCE);
  assert.equal(res.status, 'unchanged');
  assert.equal(res.text, undefined);
});
// MUTATION: delete the `res.stdout === source` check. Every Format Document
// on an already-formatted file writes the same bytes back, which costs an
// undo step and a dirty buffer for nothing.

test('C7: a real reformat comes back, whole', async () => {
  const res = await cli.formatSource(NODE, stub('reindent'), SOURCE);
  assert.equal(res.status, 'formatted');
  assert.match(res.text, /^ {4}near/m, 'two became four');
  assert.match(res.text, /^\/\/ the room$/m, 'and the prose is still there');
});

test('C8: the probe refuses a binary that swallows a comment', async () => {
  const ok = await cli.probeFormat(NODE, stub('echo'));
  assert.equal(ok.ok, true);

  const bad = await cli.probeFormat(NODE, stub('strip-comments'));
  assert.equal(bad.ok, false);
  assert.equal(bad.reason, 'mangled');
});
// MUTATION: drop the `res.stdout.includes('rill vscode probe')` test from
// probeFormat. A comment-eating binary probes clean, formatting turns itself
// on, and the only thing left between it and his prose is guard 4.

// ---------------------------------------------------------------------------
// C9 — diagnostics.
// ---------------------------------------------------------------------------

test('C9: diagnostics are read, positions and all', async () => {
  const res = await cli.checkSource(NODE, [STUB, 'check-bad', 'check', '--json', '-'], SOURCE);
  assert.equal(res.status, 'diagnostics');
  assert.equal(res.diagnostics.length, 2);
  assert.deepEqual(res.diagnostics[0], {
    line: 4, col: 12, endLine: null, endCol: null,
    severity: 'error', code: 'unknown_operator',
    message: "unknown operator or name 'fooo'",
  });
});

test('C9b: a clean parse clears the squiggles', async () => {
  const res = await cli.checkSource(NODE, [STUB, 'check-ok', 'check', '--json', '-'], SOURCE);
  assert.equal(res.status, 'ok');
  assert.deepEqual(res.diagnostics, []);
});

test('C9c: a reply nothing can read does NOT read as all-clear', async () => {
  const res = await cli.checkSource(NODE, [STUB, 'garbage', 'check', '--json', '-'], SOURCE);
  assert.equal(res.status, 'unreadable');
  assert.ok(!('diagnostics' in res), 'no diagnostics means "leave them alone", not "clear them"');
});
// MUTATION: in checkSource, return `{ status: 'ok', diagnostics: [] }` from
// the `parsed === null` branch unconditionally. A crashed checker wipes every
// squiggle in the file and the editor reports a clean parse it never got.

test('C9d: an entry with no line number is dropped, not guessed at', async () => {
  const parsed = cli.parseDiagnostics(JSON.stringify({
    diagnostics: [
      { message: 'something went wrong' },
      { line: 3, col: 7, message: 'this one knows where it is' },
    ],
  }), '');
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].line, 3);
});
// MUTATION: default the missing line to 1 instead of dropping the entry. A
// squiggle appears under the first line of the file for a fault somewhere
// else, which is worse than no squiggle.

// ---------------------------------------------------------------------------
// C10 — the outline.
// ---------------------------------------------------------------------------

function find(nodes, name) {
  for (const n of nodes) {
    if (n.name === name) return n;
    const hit = find(n.children, name);
    if (hit) return hit;
  }
  return null;
}

test('C10: the outline of the showcase — banners, def, ports, fold, streams', async () => {
  const text = await readFile(path.join(here, 'fixtures', 'showcase.rill'), 'utf8');
  const tree = outline(text);

  const stores = tree.find((n) => n.name === 'THE STORES');
  assert.ok(stores, 'a `// ══ TITLE ══` rule is a chapter');
  assert.equal(stores.kind, 'namespace');

  // A `// ── title ──` rule nests under the chapter above it.
  assert.ok(stores.children.some((n) => n.name === 'literals'));

  const fold = find(tree, ':k');
  assert.ok(fold, 'the fold is in the outline');
  assert.equal(fold.kind, 'constant');
  assert.equal(fold.detail, 'plane.drift.@self.k');

  const bound = find(tree, 'space_down');
  assert.ok(bound, 'an `as` name is in the outline');
  assert.equal(bound.kind, 'variable');

  const def = find(tree, 'scatter');
  assert.ok(def, 'the def is in the outline');
  assert.equal(def.detail, 'A worked example of a parameter pack: a default, a range and a sentence.');
  assert.deepEqual(def.children.map((c) => c.name), ['rate', 'speed', 'blend']);
  assert.equal(def.children[0].detail, ': number = 60 (0..500)');
});
// MUTATION: change symbols.js's DESCRIBE handling to skip lifting the leading
// bare string onto the def. The detail falls back to 'export def' and the
// outline stops answering "what is this", which is the question it exists for.

test('C10b: the exemplar outlines — roaches.rill is the file to make beautiful', async () => {
  // Read from the sibling checkout the way the corpus gate does; skipping is
  // not an option, so a missing sibling fails loudly rather than passing on
  // an assumption.
  const siblings = process.env.RILL_SIBLINGS || path.resolve(EXT_ROOT, '..', '..', '..');
  const roaches = path.join(siblings, 'matryoshka', 'kernels', 'roaches.rill');
  const text = await readFile(roaches, 'utf8');
  const tree = outline(text);

  const def = find(tree, 'roaches');
  assert.ok(def, 'the exported def is found');
  assert.ok(def.children.length >= 6, `found ${def.children.length} ports`);
  assert.ok(def.detail.startsWith('Cockroaches'), `detail was '${def.detail}'`);

  assert.ok(find(tree, ':k'), 'the fold is found');

  // And the prose is the spine: this file's chapters ARE its structure.
  const chapters = tree.filter((n) => n.kind === 'namespace').map((n) => n.name);
  assert.ok(chapters.length >= 4, `found chapters: ${chapters.join(' | ')}`);
  assert.ok(chapters.includes('THE KERNEL'), chapters.join(' | '));
});
// MUTATION: delete the BANNER_1/BANNER_2 branch from symbols.js. The exemplar
// outlines to one def and one fold — two entries for a 250-line file — and
// the breadcrumb stops being worth looking at.

test('C10c: `//` inside a describe string is not a comment', () => {
  // The outline scanner has to know the one rule the tokenizer knows: `//`
  // opens a comment only OUTSIDE a string. A describe line quoting a path
  // would otherwise lose half its sentence.
  const line = '    rate     "rows a second, see docs//rates for the arithmetic"';
  assert.equal(cli.countCommentLines(line), 0);
  const stripped = require(path.join(EXT_ROOT, 'src', 'symbols.js')).code(line);
  assert.ok(stripped.includes('rate'), stripped);
  // The whole sentence survives — including the half AFTER the `//`, which is
  // the half a `//`-first scanner throws away.
  assert.ok(stripped.trimEnd().endsWith('"'), `the string was cut short: ${stripped}`);
  assert.ok(!stripped.includes('//'), 'and the string is consumed, not echoed');
});
// MUTATION: delete the `if (c === '"') { inString = true; continue; }` line
// from symbols.js's `code`. The scanner breaks at the `//` inside the string,
// the describe line loses everything after it, and the `endsWith('"')`
// assertion goes red.

test('C10d: a wrapped signature outlines its ports, each on its own line', async () => {
  // THE FAILURE THIS WAS WRITTEN FOR, and it was real: `symbols.js` read the
  // port list with `src.lastIndexOf(')')` on the def's own line, on the
  // grounds that "the signature ENDS AT THE NEWLINE". Since 2026-09-09 it
  // does not — the parser accepts a break inside the parens and the printer
  // puts one port per line past 88 columns — so the exemplar this outline
  // exists for, `kernels/roaches.rill` at 234 columns, would have outlined
  // its one exported definition with NO ports at all.
  //
  // The showcase fixture is written in the wrapped form, so C10 above already
  // covers the NAMES. What this adds is the POSITIONS, which is the half a
  // one-line reader could have got right by accident.
  const text = await readFile(path.join(here, 'fixtures', 'showcase.rill'), 'utf8');
  const lines = text.split('\n');
  const def = find(outline(text), 'scatter');
  assert.ok(def);
  assert.deepEqual(def.children.map((c) => c.name), ['rate', 'speed', 'blend']);

  // Three ports, three DIFFERENT lines, each of them the line the port is
  // really on — a breadcrumb that jumped to the `def` for all three would be
  // the bug wearing a different hat.
  const at = def.children.map((c) => c.line);
  assert.equal(new Set(at).size, 3, `ports landed on lines ${at.join(', ')}`);
  for (const c of def.children) {
    assert.equal(lines[c.line].slice(c.col, c.col + c.name.length), c.name,
      `port '${c.name}' is not at ${c.line}:${c.col}`);
    assert.ok(c.line > def.line, 'a wrapped port is below the `def` line');
  }
  // …and the pack rides along as the detail, range and all.
  assert.equal(def.children[0].detail, ': number = 60 (0..500)');
  // The def's range covers the whole signature, not just its first line.
  assert.ok(def.endLine >= def.children[2].line);

  // The signature is consumed, not re-read: a port line must not also outline
  // as something of its own.
  const flat = [];
  (function walk(ns) { for (const n of ns) { flat.push(n); walk(n.children); } })(outline(text));
  for (const n of flat) {
    if (n.kind === 'field') continue;
    assert.ok(!(n.line > def.line && n.line <= def.endLine),
      `'${n.name}' (${n.kind}) outlined from inside a signature, line ${n.line}`);
  }
});
// MUTATION: in symbols.js, replace the `signature(...)` call with the old
// one-line read — `const close = src.lastIndexOf(')'); const inner = close >
// open ? src.slice(open + 1, close) : ''` and `at` positions on line `i`.
// `scatter` outlines with no children and this goes red on the first
// deepEqual, along with C10.
