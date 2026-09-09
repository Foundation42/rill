// The language configuration's gates.
//
// `language-configuration.json` is data VSCode reads and never validates, so
// a typo in it is silent: the indent rule simply stops firing and nobody
// notices for a month. These run its regexes against the shapes they are for.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(here, '..');

const langCfg = JSON.parse(await readFile(path.join(EXT_ROOT, 'language-configuration.json'), 'utf8'));
const pkg = JSON.parse(await readFile(path.join(EXT_ROOT, 'package.json'), 'utf8'));

test('L1: four spaces, everywhere', () => {
  // Ruled 2026-09-09 ('four everywhere'), and it is one constant in the
  // printer (`script.zig`'s `indent_canon`) rather than one per site. An
  // editor that inserts two would fight the formatter on every save.
  const rill = pkg.contributes.configurationDefaults['[rill]'];
  assert.equal(rill['editor.tabSize'], 4);
  assert.equal(rill['editor.insertSpaces'], true);
});
// MUTATION: set editor.tabSize to 2. Every def body and describe block he
// types is two spaces out from what `zig build roundtrip` prints back.

test('L2: `//` is the line comment, and there is no block comment', () => {
  assert.equal(langCfg.comments.lineComment, '//');
  assert.ok(!('blockComment' in langCfg.comments),
    'rill has none, so offering one offers a syntax error');
});
// MUTATION: add `"blockComment": ["/*", "*/"]`. Alt+Shift+A writes two tokens
// the tokenizer refuses, in a file that was valid a keystroke earlier.

test('L3: the word pattern is the tokenizer\'s word', () => {
  const word = new RegExp(langCfg.wordPattern, 'g');
  const wholeMatch = (s) => {
    word.lastIndex = 0;
    const m = word.exec(s);
    return m && m.index === 0 && m[0].length === s.length;
  };
  // Sigils are IN the word: `:k` and `$wind` are one token each, and a
  // double-click that took only `k` would take half a name.
  for (const s of [':k', '$wind', '@self', '#in-courtyard', '^raider']) {
    assert.ok(wholeMatch(s), `'${s}' is one word`);
  }
  // `-` and `/` join two name characters, so a knob path is one word.
  assert.ok(wholeMatch('render/grade/exposure'));
  assert.ok(wholeMatch('key-light'));
  // A duration is a number glued to a unit.
  assert.ok(wholeMatch('250ms'));
  // The dot is NOT in the pattern: a path is its segments, not one word.
  word.lastIndex = 0;
  assert.equal(word.exec('plane.drift.@self')[0], 'plane');
});
// MUTATION: drop the `[:$@#^]?` prefix from the word pattern. `:k` selects as
// `k`, so Ctrl+D across a file finds the `k` inside `plane.drift.@self.k` and
// misses every fold reference.

test('L4: the indent rule fires on the three things that open a body', () => {
  const inc = new RegExp(langCfg.indentationRules.increaseIndentPattern);
  const dec = new RegExp(langCfg.indentationRules.decreaseIndentPattern);
  for (const line of [
    'export def roaches(rate = 60 (0..500)) =',
    'def spin(x: number) on row =',
    'describe roaches',
    'plane.orders.sally | also {',
    'row.age | over row.life [',
  ]) {
    assert.ok(inc.test(line), `should indent after: ${line}`);
  }
  for (const line of ['near :k.tight | write row.u3', '// a comment', 'spawn']) {
    assert.ok(!inc.test(line), `should NOT indent after: ${line}`);
  }
  assert.ok(dec.test('    }'));
  assert.ok(dec.test('  ]'));
});
// MUTATION: drop the `describe\s+…` alternative from increaseIndentPattern.
// A describe block's first line lands in the left margin, where `t.col <=
// kw.col` ends the block before it starts — the parser reads an exported def
// with no descriptions and refuses it.

test('L5: a `//` line continues on Enter', () => {
  // Four-fifths of the exemplar is prose. This is the one opinionated default
  // in the extension and it is opinionated on purpose.
  const rule = langCfg.onEnterRules.find((r) => r.action.appendText === '// ');
  assert.ok(rule, 'the comment continuation rule is there');
  assert.ok(new RegExp(rule.beforeText).test('// roaches — THE EXEMPLAR.'));
  assert.ok(new RegExp(rule.beforeText).test('    // indented prose'));
  assert.ok(!new RegExp(rule.beforeText).test('near :k.tight'));
});

test('L6: the grammar file is the one the manifest points at', async () => {
  const grammars = pkg.contributes.grammars;
  assert.equal(grammars.length, 1);
  assert.equal(grammars[0].scopeName, 'source.rill');
  const raw = JSON.parse(await readFile(path.join(EXT_ROOT, grammars[0].path), 'utf8'));
  assert.equal(raw.scopeName, 'source.rill');
  assert.equal(pkg.contributes.languages[0].configuration, './language-configuration.json');
  const snippets = JSON.parse(await readFile(path.join(EXT_ROOT, pkg.contributes.snippets[0].path), 'utf8'));
  assert.ok(Object.keys(snippets).length > 1, 'the snippets file parses and is not empty');
});
// MUTATION: point contributes.grammars[0].path at a file that does not exist.
// VSCode logs it once at startup and highlights nothing; nobody reads that
// log. This goes red instead.

// ---------------------------------------------------------------------------
// L7 / L8 / L9 — the wrapped forms (the width canon, 2026-09-09).
//
// The governing idea is that TYPING must agree with the PRINTER. Format on
// save is about to be wired to `rill fmt`, so an editor whose Enter puts a
// continuation somewhere the printer would not moves the author's cursor on
// every save — and the plugin's job is to make the formatter invisible, not
// to fight it.
// ---------------------------------------------------------------------------

test('L7: the indent rules follow a line that the printer breaks', () => {
  const inc = new RegExp(langCfg.indentationRules.increaseIndentPattern);
  const dec = new RegExp(langCfg.indentationRules.decreaseIndentPattern);

  // A signature that wraps opens with a bare `(` at end of line…
  assert.ok(inc.test('export def roaches('));
  // …and closes on a line that must do BOTH: dedent itself back to the
  // `def`'s column, then indent the body under it. This is the one the width
  // canon added — without it the body of every wrapped definition lands in
  // the left margin, where a def's dedent rule ends the body before it starts.
  for (const line of [') =', ') on row =', '    ) =']) {
    assert.ok(inc.test(line), `should indent after: ${line}`);
    assert.ok(dec.test(line), `should dedent itself: ${line}`);
  }
  // A port line is neither — it is inside the parens and stays where it is.
  assert.ok(!inc.test('    rate = 60 (0..500),'));
  assert.ok(!dec.test('    rate = 60 (0..500),'));
  // A wrapped span: the `[` opens, the `]` closes, and a trailing flag after
  // the closer (`] loop`) does not stop it closing.
  assert.ok(inc.test('    | over plane.life ['));
  assert.ok(dec.test('    ]'));
  assert.ok(dec.test('    ] loop'));
  assert.ok(!inc.test('        {l: 1.5, a: 0.08},'));
  // And a continuation stage is not an opener: it must not indent the line
  // under it, or a three-stage chain walks off the right of the screen.
  assert.ok(!inc.test('    | write plane.colour'));
});
// MUTATION: delete the `\)(?:\s+on\s+[A-Za-z_]\w*)?\s*=\s*$` alternative from
// increaseIndentPattern. `) =` stops indenting, the body of every wrapped
// definition is typed in the left margin, and the four `) =` assertions go
// red. (Deleting it is also what the file looked like before this beat, which
// is the point: it worked because a signature could not wrap.)

test('L8: a `|` continuation keeps the printer\'s column on Enter', () => {
  const rule = langCfg.onEnterRules.find((r) => r.action.appendText === '| ');
  assert.ok(rule, 'the pipe continuation rule is there');
  const before = new RegExp(rule.beforeText);
  assert.ok(before.test('    | over plane.life [{l: 1.5}]'), 'an indented continuation');
  assert.ok(before.test('| cooldown 5m'), 'and one in the left margin');
  // `indent: "none"` is the load-bearing word. The printer puts every stage
  // of a broken chain in ONE column, so an Enter that indented would step the
  // chain rightwards a stage at a time and the formatter would step it back
  // on save — the cursor jumping on every save is exactly what this plugin
  // exists not to do.
  assert.equal(rule.action.indent, 'none');
  // A statement is not a continuation: no pipe, no rule.
  assert.ok(!before.test('plane.t | over plane.life [{l: 1.5}]'));
  assert.ok(!before.test('spawn'));
});
// MUTATION: change the rule's action to `{ "indent": "indent", "appendText":
// "| " }`. Every Enter inside a wrapped chain adds four columns, the save
// takes them away, and the `indent` assertion goes red.

test('L9: the snippets are written in the canon the printer prints', () => {
  // A snippet is a shape the author is TAUGHT. One that lands over the width
  // is reflowed by the first save, and one wrapped for the look of it is
  // flattened by the first save — both teach a shape the tool disagrees with,
  // so this checks both directions.
  const snippets = JSON.parse(readFileSync(path.join(EXT_ROOT, 'snippets', 'rill.json'), 'utf8'));

  // A snippet body with its placeholders taken at their defaults: `${3:60}`
  // is `60` and `${8|add,alpha|}` is the first choice, which is what lands in
  // the buffer if the author tabs straight through.
  const resolve = (t) => t
    .replace(/\$\{\d+\|([^|]*)\|\}/g, (_, choices) => choices.split(',')[0])
    .replace(/\$\{\d+:((?:[^{}\\]|\\.)*)\}/g, (_, d) => d)
    .replace(/\$\{\d+\}/g, '')
    .replace(/\$0/g, '')
    .replace(/\$\d+/g, '');

  const long = [];
  for (const [name, snip] of Object.entries(snippets)) {
    if (name === '//') continue;
    let inDescribe = false;
    for (const line of snip.body) {
      const text = resolve(line);
      // A `describe` block's lines are the one thing the width does not
      // reach: a key and one string, and a string cannot be broken without
      // changing the value it holds. The block ends at a dedent, exactly as
      // it does in the parser.
      if (/^describe\s/.test(text)) { inDescribe = true; continue; }
      if (inDescribe && !/^\s/.test(text) && text.trim() !== '') inDescribe = false;
      if (inDescribe) continue;
      if (text.length > 88) long.push(`${name}: [${text.length}] ${text.slice(0, 60)}…`);
    }
  }
  assert.deepEqual(long, [], 'a snippet line the printer would reflow');

  // …and the one signature that IS over the width is written broken, one
  // port per line, exactly as the printer writes it. Measured: with its
  // placeholders resolved, the whole `kernel` snippet is a fixed point of
  // `zig build roundtrip`.
  const kernel = Object.values(snippets).find((s) => s.prefix === 'kernel').body;
  const open = kernel.findIndex((l) => /^export def .*\($/.test(l));
  assert.ok(open >= 0, 'the spray package opens its signature with a bare `(`');
  assert.equal(kernel[open + 1], '    rate = ${3:60} (0..500),');
  assert.equal(kernel[kernel.indexOf(') =') - 1], '    blend = "${8|add,alpha|}"',
    'the last port carries no trailing comma — the printer emits none');

  // The three small def snippets are NOT wrapped: their signatures fit, and a
  // snippet wrapped for the look of it is flattened on the first save.
  for (const prefix of ['exportdef', 'def', 'defrow']) {
    const body = Object.values(snippets).find((s) => s.prefix === prefix).body;
    assert.ok(body.some((l) => /^(export )?def .*\)(?: on \w+)? =$/.test(l)),
      `${prefix} keeps its signature on one line`);
  }
});
// MUTATION: flatten the spray package's signature back onto one line (149
// columns). The width check and the `open >= 0` assertion both go red.
