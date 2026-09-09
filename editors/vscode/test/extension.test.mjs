// The extension's own gates — the layer that actually touches a document.
//
// `client.test.mjs` stops at a status. This runs the providers that turn that
// status into a `TextEdit`, because the way to empty a file is to be right
// about the status and wrong about the edit.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(here, '..');

const fake = require(path.join(here, 'fake-vscode.cjs'));
fake.install();

const STUB = path.join(here, 'stubs', 'rill.mjs');

function activate(settings) {
  fake.reset(settings);
  // Fresh each time: `told` and the format probe are module state, and a
  // session that has already said "no binary" says nothing the second time —
  // which is the behaviour, and which would make the next gate measure the
  // silence instead of the answer.
  delete require.cache[require.resolve(path.join(EXT_ROOT, 'src', 'extension.js'))];
  const ext = require(path.join(EXT_ROOT, 'src', 'extension.js'));
  const context = { subscriptions: [] };
  ext.activate(context);
  return { ext, context };
}

test('E1: it activates, and registers what it says it does', () => {
  const { context } = activate();
  assert.equal(fake.log.symbolProviders.length, 1);
  assert.equal(fake.log.formatProviders.length, 1);
  assert.ok(fake.log.commands.has('rill.checkBinary'));
  assert.ok(context.subscriptions.length > 5, 'everything registered is disposable');
});

test('E2: the exemplar gets an outline, and every range is legal', async () => {
  activate();
  const siblings = process.env.RILL_SIBLINGS || path.resolve(EXT_ROOT, '..', '..', '..');
  const text = await readFile(path.join(siblings, 'matryoshka', 'kernels', 'roaches.rill'), 'utf8');

  // The DocumentSymbol stub throws when a selection range escapes its parent,
  // exactly as VSCode does — and a thrown outline is a silently empty one, so
  // building it at all is half the assertion.
  const symbols = fake.log.symbolProviders[0].provideDocumentSymbols(fake.document(text));
  assert.ok(symbols.length >= 4, `${symbols.length} top-level symbols`);

  const flat = [];
  (function walk(list) { for (const s of list) { flat.push(s); walk(s.children); } }(symbols));
  assert.ok(flat.some((s) => s.name === 'roaches' && s.children.length >= 6));
  assert.ok(flat.some((s) => s.name === ':k'));
});
// MUTATION: in extension.js's `toSymbols`, pass `sel` unconditionally instead
// of `full.contains(sel) ? sel : full`. A banner whose end line is its own
// line throws, the provider throws, and VSCode shows no outline at all — this
// goes red where the editor would have gone quiet.

test('E3: no binary → the provider returns NO edits', async () => {
  const { ext } = activate({ binaryPath: '/nonexistent/rill-does-not-exist' });
  void ext;
  const doc = fake.document('// prose worth keeping\nspawn\nperish\n');
  const edits = await fake.log.formatProviders[0].provideDocumentFormattingEdits(doc);
  assert.deepEqual(edits, [], 'an empty edit list is a document left alone');
  assert.equal(fake.log.errors.length, 0, 'and no wall of errors');
  assert.equal(fake.log.warnings.length, 0);
  assert.equal(fake.log.status.length, 1, 'one line, once');
  assert.match(fake.log.status[0], /rill\.binaryPath/);
});
// MUTATION: in the format provider, `return [];` becomes
// `return [vscode.TextEdit.replace(whole, res.text ?? '')]` for every status.
// The document is replaced with nothing on the very first save after install,
// when there is no binary yet — which is every install.

test('E4: a comment-eating binary is refused at the provider, loudly', async () => {
  activate({ binaryPath: process.execPath, 'format.args': [STUB, 'strip-comments', 'fmt', '-'] });
  const doc = fake.document('// prose worth keeping\nspawn\nperish\n');
  const edits = await fake.log.formatProviders[0].provideDocumentFormattingEdits(doc);
  assert.deepEqual(edits, []);
  // The probe catches it first, and that one is a popup rather than a status
  // line: a formatter that deletes prose is not a "quietly unavailable".
  assert.equal(fake.log.warnings.length, 1, fake.log.warnings.join(' | '));
  assert.match(fake.log.warnings[0], /without its comments/);
});

test('E5: a working binary formats, and the edit covers the whole document', async () => {
  activate({ binaryPath: process.execPath, 'format.args': [STUB, 'reindent', 'fmt', '-'] });
  const text = '// prose\nspawn\n  near 0.5 | write row.u3\n';
  const doc = fake.document(text);
  const edits = await fake.log.formatProviders[0].provideDocumentFormattingEdits(doc);
  assert.equal(edits.length, 1);
  assert.equal(edits[0].range.start.line, 0);
  assert.equal(edits[0].range.start.character, 0);
  assert.equal(edits[0].range.end.line, doc.lineCount - 1);
  assert.match(edits[0].newText, /^ {4}near/m);
  assert.match(edits[0].newText, /^\/\/ prose$/m);
});
// MUTATION: build the replace range from `document.positionAt(0)` to
// `document.positionAt(source.length - 1)`. The last character of the file is
// left behind on every format — a trailing newline today, and a `}` on the day
// somebody formats a file that does not end in one.

test('E6: an unknown name is a warning, not an error — the registry is open', () => {
  const { ext } = activate();
  const doc = fake.document('spawn\nperish\nfooo 1\n');
  const diags = [
    { line: 3, col: 1, endLine: null, endCol: null, severity: 'error', code: 'unknown_operator', message: "unknown operator or name 'fooo'" },
    { line: 2, col: 1, endLine: null, endCol: null, severity: 'error', code: 'parse', message: 'expected name' },
  ];
  const cfg = fake.vscode.workspace.getConfiguration();

  const made = ext.makeDiagnostics(doc, diags, cfg);
  assert.equal(made.length, 2);
  // rill core does not know `spawn`, `near` or `drift` — those are
  // spindrift's and matryoshka's — so a name it has never heard of is not
  // necessarily a mistake. 21 of the 47 corpus files would go red otherwise.
  assert.equal(made[0].severity, fake.vscode.DiagnosticSeverity.Warning, 'unknown_operator is downgraded');
  assert.equal(made[1].severity, fake.vscode.DiagnosticSeverity.Error, 'a real parse error is not');
  assert.equal(made[0].source, 'rill');
  assert.equal(made[0].code, 'unknown_operator');

  // And it is a setting, so a workspace that names its host's words gets the
  // error back.
  fake.log.settings = { 'diagnostics.unknownNames': 'off' };
  assert.equal(ext.makeDiagnostics(doc, diags, cfg).length, 1, 'off drops it entirely');
});
// MUTATION: in makeDiagnostics, delete the `d.code === 'unknown_operator'`
// branch. Every host word in every kernel is an error squiggle the moment
// diagnostics are switched on, which is the state that makes a person turn
// the feature off and never turn it back on.

test('E7: the squiggle covers the token, not one character of it', () => {
  const { ext } = activate();
  const doc = fake.document('spawn\nnear :k.tight | write row.u3\n');
  // `Diag` carries a line and a column and no end, so the end is derived from
  // the document. A one-character squiggle under a ten-character name is
  // technically right and useless.
  const span = ext.spanFor(doc, { line: 2, col: 6, endLine: null, endCol: null });
  assert.equal(span.start.line, 1);
  assert.equal(span.start.character, 5);
  assert.equal(span.end.character, 13, 'the whole of `:k.tight` — sigil, projection and all');

  // And when the checker DOES send an end, that wins.
  const given = ext.spanFor(doc, { line: 2, col: 1, endLine: 2, endCol: 5 });
  assert.equal(given.end.character, 4);
});
// MUTATION: drop the `(?:\\.${NAME})*` continuation from spanFor's regex. The
// squiggle stops at the first dot, so a refusal on a twenty-character path
// underlines five characters of it and the eye goes to the wrong place.

test('E8: a file that will not parse leaves the document alone — and says why, once', async () => {
  // Added the day the binary became real (2026-09-09), because that is the
  // day this stopped being hypothetical: with the SHIPPED `rill.format.args`
  // a `rill` built from core alone exits 65 on all 21 spray kernels in this
  // checkout, `kernels/roaches.rill` included. The document must not move —
  // and the person must not be left pressing a key that does nothing.
  activate({ binaryPath: process.execPath, 'format.args': [STUB, 'no-host', 'fmt', '-'] });
  const doc = fake.document('// prose worth keeping\nnear 0.5\n');
  const edits = await fake.log.formatProviders[0].provideDocumentFormattingEdits(doc);
  assert.deepEqual(edits, [], 'a file that does not parse is a file left alone');
  assert.equal(fake.log.errors.length, 0, 'and not a popup — the squiggle already said it');
  assert.equal(fake.log.warnings.length, 0);
  assert.equal(fake.log.status.length, 1, `one line, once: ${fake.log.status.join(' | ')}`);
  assert.match(fake.log.status[0], /--host-row/, 'and it names the setting that fixes it');

  // Twice, because `told` is what keeps this from becoming a wall.
  await fake.log.formatProviders[0].provideDocumentFormattingEdits(doc);
  assert.equal(fake.log.status.length, 1, 'still once');
});
// MUTATION: delete the `say(...)` from the format provider's 'parse-error'
// case. Format Document on a spray kernel does nothing, silently, for ever —
// which is the state the extension shipped in this morning and the reason
// nobody would have found the missing flag.
