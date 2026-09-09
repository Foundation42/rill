// The language configuration's gates.
//
// `language-configuration.json` is data VSCode reads and never validates, so
// a typo in it is silent: the indent rule simply stops firing and nobody
// notices for a month. These run its regexes against the shapes they are for.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
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
