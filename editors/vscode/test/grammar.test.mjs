// The grammar's gates.
//
// "I looked at it" is not a gate. Each test below names the mutation that
// makes it fail, and `npm run mutate` applies every one of them to a copy of
// the tree and asserts the named test goes red. A gate that cannot fail is
// decoration.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile, stat } from 'node:fs/promises';
import * as path from 'node:path';
import { loadGrammar, tokenize, scopesAt, tokenNamed, isClassified, EXT_ROOT } from './tmgrammar.mjs';

const grammar = await loadGrammar(process.env.RILL_GRAMMAR);

/** Tokenize a snippet and give back both the tokens and a scope lookup. */
function lex(source) {
  return tokenize(grammar, source);
}

function scopesOfText(tokens, text, nth = 0) {
  const t = tokenNamed(tokens, text, nth);
  assert.ok(t, `no token spelled exactly '${text}'`);
  return t.scopes;
}

/** Does any character in `tokens` carry a scope with this prefix? */
function anyScope(tokens, prefix) {
  return tokens.some((t) => t.scopes.some((s) => s.startsWith(prefix)));
}

// ---------------------------------------------------------------------------
// G1 — the corpus. All 47 programs, every character classified.
// ---------------------------------------------------------------------------

async function walk(dir, out) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.name === '.git' || e.name === '.zig-cache' || e.name === 'node_modules') continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) await walk(full, out);
    else if (e.isFile() && e.name.endsWith('.rill')) out.push(full);
  }
  return out;
}

async function corpus() {
  // rill is the library the siblings embed; the corpus lives in them, which
  // is exactly why `tools/roundtrip.zig` takes the files as arguments rather
  // than building them in. Same arrangement here.
  const repo = path.resolve(EXT_ROOT, '..', '..');
  // `RILL_SIBLINGS` is what lets the mutation runner work on a copy of the
  // tree without the corpus gate failing for the wrong reason — a mutation
  // that "bites" because the fixtures moved has measured nothing.
  const parent = process.env.RILL_SIBLINGS || path.resolve(repo, '..');
  const roots = [repo, path.join(parent, 'spindrift'), path.join(parent, 'matryoshka')];
  const files = [];
  for (const root of roots) {
    try { await stat(root); } catch { continue; }
    await walk(root, files);
  }
  return files.sort();
}

test('G1: every character of every corpus program is classified', async () => {
  const files = await corpus();
  // The corpus was 47 files on 2026-09-09 (8 in spindrift, 39 in matryoshka).
  // A floor rather than an equality: a new kernel must not silently turn this
  // gate into a no-op, and a new kernel must not have to edit a test either.
  assert.ok(
    files.length >= 40,
    `expected the sibling corpus (47 files on 2026-09-09), found ${files.length}. `
    + 'Run this from a checkout with spindrift and matryoshka beside rill.',
  );

  const problems = [];
  for (const file of files) {
    const text = await readFile(file, 'utf8');
    const tokens = lex(text);
    const lines = text.split('\n');
    for (const t of tokens) {
      for (let c = t.startIndex; c < t.endIndex; c += 1) {
        const ch = lines[t.line][c];
        if (ch === undefined || /\s/.test(ch)) continue;
        if (!isClassified(t.scopes)) {
          problems.push(`${file}:${t.line + 1}:${c + 1} '${ch}' unclassified (${t.scopes.join(' ')})`);
        } else if (t.scopes.some((s) => s.startsWith('invalid.'))) {
          problems.push(`${file}:${t.line + 1}:${c + 1} '${t.text}' is ${t.scopes.filter((s) => s.startsWith('invalid.')).join(' ')}`);
        }
      }
    }
  }
  assert.deepEqual(problems.slice(0, 20), [], `${problems.length} problems, first 20 shown`);
});
// MUTATION: delete `{ "include": "#bare-word" }` from the grammar's top-level
// `patterns`. Every argument, flag and write mode in the corpus falls to the
// root scope and this goes red on the first file.

test('G1b: the showcase fixture is classified too', async () => {
  const file = path.join(EXT_ROOT, 'test', 'fixtures', 'showcase.rill');
  const text = await readFile(file, 'utf8');
  const tokens = lex(text);
  const lines = text.split('\n');
  const problems = [];
  for (const t of tokens) {
    for (let c = t.startIndex; c < t.endIndex; c += 1) {
      const ch = lines[t.line][c];
      if (ch === undefined || /\s/.test(ch)) continue;
      if (!isClassified(t.scopes) || t.scopes.some((s) => s.startsWith('invalid.'))) {
        problems.push(`${t.line + 1}:${c + 1} '${ch}' → ${t.scopes.join(' ')}`);
      }
    }
  }
  assert.deepEqual(problems, []);
});

// ---------------------------------------------------------------------------
// G2 — `//` opens a comment and `#` does not. Ruled 2026-08-25.
// ---------------------------------------------------------------------------

test('G2: `//` is a comment and `#` is the tag sigil, not one', () => {
  const tokens = lex('tag @tom #garrison // and this is the comment\n');
  const hash = scopesOfText(tokens, '#garrison');
  assert.ok(
    hash.includes('entity.name.tag.condition.rill'),
    `#garrison scoped as ${hash.join(' ')}`,
  );
  assert.ok(!hash.some((s) => s.startsWith('comment.')), '#garrison must not be a comment');

  const comment = tokens.filter((t) => t.scopes.some((s) => s.startsWith('comment.')));
  assert.ok(comment.length > 0, 'the `//` run is a comment');
  assert.ok(comment.every((t) => t.line === 0 && t.startIndex >= 18), 'the comment starts at the //');
});
// MUTATION: change #comment's match to "(//|#).*$". `#garrison` becomes a
// comment and both halves of this go red.

test('G2b: `render/grade/exposure` is one word, so its slashes are not a comment', () => {
  const tokens = lex('plane.input.mouse.lmb | write plane.render/grade/exposure stops\n');
  assert.ok(!anyScope(tokens, 'comment.'), 'no comment anywhere on this line');
  const seg = scopesOfText(tokens, 'render/grade/exposure');
  assert.ok(seg.includes('variable.other.member.rill'), `scoped as ${seg.join(' ')}`);
});
// MUTATION: drop the `(?:[-/][\w]+)*` joiner from #member's second capture.
// The path segment stops at `render`, `/grade/exposure` falls through, and
// the `//`-boundary claim this file makes is no longer true of the grammar.

// ---------------------------------------------------------------------------
// G3 — the fold. `:k.tight` is ONE reference plus a projection, never a path.
// ---------------------------------------------------------------------------

test('G3: `:k.tight` scopes as one fold reference and not as a path', () => {
  const tokens = lex('near :k.tight | write row.u3\n');

  // The colon is IN the token, exactly as `$chan`'s sigil is in its own.
  const fold = scopesOfText(tokens, ':k');
  assert.ok(fold.includes('variable.other.constant.fold.rill'), `:k scoped as ${fold.join(' ')}`);
  assert.ok(!fold.includes('support.class.plane.rill'), 'a fold is tokens, not a store');

  // And nothing on this line is a bare colon: `:` and `k` are not two tokens.
  assert.equal(tokenNamed(tokens, ':'), null, '`:` must not lex on its own here');

  // The projection off it is an ordinary member, because that is what it is:
  // `:k.tight` expands to `plane.drift.@self.k.tight`.
  assert.ok(scopesOfText(tokens, 'tight').includes('variable.other.member.rill'));

  // And `near` is the operator, not a keyword argument.
  assert.ok(scopesOfText(tokens, 'near').includes('entity.name.function.rill'));
});
// MUTATION: delete `{ "include": "#fold" }` from the top-level patterns.
// `:k` splits into a bare `:` and a bare word, and three of the four
// assertions above go red.

test('G3b: a kwarg colon glues LEFT and a fold colon glues RIGHT', () => {
  // `colonOpensFold` decides by ADJACENCY, not position. Both spellings on
  // one line, because that is the pair the rule exists to separate.
  const tokens = lex('cast $tilt at: row.pos radius :k.reach\n');

  const at = scopesOfText(tokens, 'at');
  assert.ok(at.includes('variable.other.property.rill'), `at: scoped as ${at.join(' ')}`);

  const radius = scopesOfText(tokens, 'radius');
  assert.ok(
    !radius.includes('variable.other.property.rill'),
    '`radius :k.reach` is an argument and a fold, not a keyword pair',
  );
  assert.ok(scopesOfText(tokens, ':k').includes('variable.other.constant.fold.rill'));
});
// MUTATION: allow whitespace before the colon in #record-key —
// "([A-Za-z_][\w]*(?:[-/][\w]+)*)\s*(:)". `radius :k.reach` reads as the
// kwarg `radius:` with `k.reach` for a value, which is the exact silent
// mis-pairing `colonOpensFold`'s docstring says position alone would cause.

// ---------------------------------------------------------------------------
// G4 — the sigils keep them.
// ---------------------------------------------------------------------------

test('G4: `$wind` keeps its sigil, and `@self` is not `@roaches`', () => {
  const tokens = lex('$wind grad at row.pos | mul plane.drift.@self.k.lean | write plane.drift.@roaches.k.flock\n');

  const chan = tokenNamed(tokens, '$wind');
  assert.ok(chan, '`$wind` is ONE token, sigil included');
  assert.ok(chan.scopes.includes('entity.name.tag.channel.rill'));
  // The `$` itself carries the scope — not a punctuation scope beside it.
  assert.ok(
    scopesAt(tokens, 0, 0).includes('entity.name.tag.channel.rill'),
    'the sigil is inside the name, the way the tokenizer has it',
  );

  assert.ok(scopesOfText(tokens, '@self').includes('variable.language.self.rill'));
  assert.ok(scopesOfText(tokens, '@roaches').includes('entity.name.tag.entity.rill'));
});
// MUTATION: split the sigil off in #sigil — match "(\\$)([A-Za-z_][\\w]*)"
// with capture 1 as `punctuation.definition.variable.rill`. `$wind` is still
// one token but column 0 no longer carries the channel scope, and the second
// assertion goes red.

// ---------------------------------------------------------------------------
// G5 — the two-word lookup.
// ---------------------------------------------------------------------------

test('G5: a two-word operator scopes as an operator, both words', () => {
  const tokens = lex('rbf through 4 | write plane.field.value\n');
  assert.ok(scopesOfText(tokens, 'rbf').includes('entity.name.function.rill'));
  assert.ok(
    scopesOfText(tokens, 'through').includes('entity.name.function.rill'),
    'lookup tries the two-word form FIRST, so the sub-op is part of the verb',
  );
});
// MUTATION: delete `{ "include": "#operator-head-two-word" }` from the
// top-level patterns. `through` falls to #bare-word and the second assertion
// goes red.

test('G5b: a one-word operator with a stream argument is NOT two words', () => {
  // `along track loop` and `rbf through` are the same two tokens to a
  // highlighter. This is the case the closed list exists to protect.
  const tokens = lex('t | along track loop as here\n');
  assert.ok(scopesOfText(tokens, 'along').includes('entity.name.function.rill'));
  assert.ok(
    scopesOfText(tokens, 'track').includes('variable.other.rill'),
    '`track` is a local stream, not half a verb',
  );
});
// MUTATION: add a generic two-word rule to #operator-head-two-word —
// "^([ \t]*)([A-Za-z_][\w]*)([ \t]+)([A-Za-z_][\w]*)" with both names scoped
// as functions. Every curve-drawing kernel in matryoshka goes yellow and this
// goes red, which is the measurement that closed the list.

// ---------------------------------------------------------------------------
// G6 — the tail-port trap.
// ---------------------------------------------------------------------------

test('G6: a tail-port locator is not mangled', () => {
  // A `tail` port binds the rest of the line VERBATIM from raw source
  // (§3.11), and only the registry knows a port is one — so the grammar
  // cannot highlight a tail AS a tail. What it owes is that the locator comes
  // out intact: nothing invalid, nothing swallowed into a string or a
  // comment, and no `:` read as a fold.
  const tokens = lex('sound play /tmp/loop.wav\nemitter sample pack:horns#audio.stem\n');

  assert.ok(!anyScope(tokens, 'invalid.'), 'a locator is text; nothing in it is illegal');
  assert.ok(!anyScope(tokens, 'comment.'), 'nothing here is a comment');
  assert.ok(!anyScope(tokens, 'string.quoted'), 'nothing here opens a quoted string');
  assert.ok(
    !anyScope(tokens, 'variable.other.constant.fold.'),
    '`pack:horns` glues its colon LEFT, so it is not a fold',
  );

  // The `/`-led locator comes out WHOLE — one run of text, not a stray slash
  // followed by a joined name followed by a projection.
  const loc = tokenNamed(tokens, '/tmp/loop.wav');
  assert.ok(loc, 'the locator is one token');
  assert.ok(loc.scopes.includes('string.unquoted.locator.rill'));

  // The other spelling has no slash to lead it, so it stays structured — and
  // that is fine: every piece survives with its own scope and nothing is
  // swallowed. `#audio` reads as a condition, which is what it looks like.
  for (const piece of ['pack', 'horns', '#audio', 'stem']) {
    assert.ok(tokenNamed(tokens, piece), `'${piece}' survives the line`);
  }
});
// MUTATION: remove the adjacency guard from #fold — drop the
// "(?:^|(?<=[\s(\[{,|]))" prefix. `pack:horns#audio.stem` reads `:horns` as a
// fold reference, which is the mis-lex `colonOpensFold` was written to
// prevent, and the fourth assertion goes red.

// ---------------------------------------------------------------------------
// G7 — head position, and the four things that are not a verb.
// ---------------------------------------------------------------------------

test('G7: a path head at the start of a statement is a path, not a verb', () => {
  const tokens = lex('plane.input.kbd.d | sub plane.input.kbd.a | write plane.camera.thrust.right add\n');
  const head = scopesOfText(tokens, 'plane');
  assert.ok(head.includes('support.class.plane.rill'), `plane scoped as ${head.join(' ')}`);
  assert.ok(!head.includes('entity.name.function.rill'), 'a store is not a verb');
  assert.ok(scopesOfText(tokens, 'sub').includes('entity.name.function.rill'));
  assert.ok(scopesOfText(tokens, 'add').includes('variable.other.rill'), 'a trailing write mode is a word');

  // INDENTED, which is the case the head rule's guard actually buys: at
  // column 0 the path-head rule wins on list order anyway, and an indented
  // line is where a head rule that starts at the margin would beat it.
  const inner = lex('    row.age | over row.life [1, 0] | write row.size\n');
  assert.ok(scopesOfText(inner, 'row', 0).includes('support.class.plane.rill'),
    'an indented path-headed statement is still a path');
});
// MUTATIONS, two, because the claim has two halves and each is masked by the
// other at column 0:
//   G7        delete `{ "include": "#path-head" }`. The three stores lose
//             their scope and `plane` falls to #bare-word.
//   G7-indent drop the "(?![\w.:/-])" guard from #operator-head. The head
//             rule starts at the left margin, beats #path-head on position,
//             and every indented path-headed statement goes yellow.

test('G7b: `row` is a store in a chain and a plane in a signature', () => {
  const tokens = lex('def spin(x: number) on row =\n    x | mul row.age | write row.size\n');
  assert.ok(scopesOfText(tokens, 'def').includes('storage.type.function.rill'));
  assert.ok(scopesOfText(tokens, 'spin').includes('entity.name.function.definition.rill'));
  assert.ok(scopesOfText(tokens, 'x').includes('variable.parameter.rill'), 'a port is a parameter');
  assert.ok(scopesOfText(tokens, 'number').includes('entity.name.type.rill'));
  assert.ok(scopesOfText(tokens, 'on').includes('keyword.control.on.rill'));
  // `on row` names the PLANE; `row.age` names the store.
  assert.ok(scopesOfText(tokens, 'row', 0).includes('entity.name.type.plane.rill'));
  assert.ok(scopesOfText(tokens, 'row', 1).includes('support.class.plane.rill'));

  // A def body may sit on the signature's own line, and the signature ends at
  // the `=` for exactly that reason. Nothing after it is a port.
  const oneLine = lex('def healthbar(hp: number) = hp | clamp 0 100 | div 100\n');
  assert.ok(scopesOfText(oneLine, '=').includes('keyword.operator.assignment.rill'));
  assert.ok(scopesOfText(oneLine, 'clamp').includes('entity.name.function.rill'),
    'the body is a chain, not a continuation of the signature');
  assert.ok(scopesOfText(oneLine, '100', 0).includes('constant.numeric.rill'));
});
// MUTATION: change #def-signature's `end` from "(=)|$" to "$". A one-line
// def's body stays inside the signature context, where nothing matches it, so
// `clamp` and `100` come out unclassified and the last two assertions go red.
// (The multi-line case cannot see this: `$` already ends at the newline.)

test('G7c: the parameter pack — default, range and type', () => {
  const tokens = lex('export def roaches(rate = 60 (0..500), blend = "add") =\n    0\n');
  assert.ok(scopesOfText(tokens, 'export').includes('storage.modifier.export.rill'));
  assert.ok(scopesOfText(tokens, 'rate').includes('variable.parameter.rill'));
  assert.ok(scopesOfText(tokens, '60').includes('constant.numeric.rill'));
  assert.ok(scopesOfText(tokens, '..').includes('keyword.operator.range.rill'));
  assert.ok(scopesOfText(tokens, '0', 0).includes('constant.numeric.rill'));
  assert.ok(scopesOfText(tokens, '500').includes('constant.numeric.rill'));
  assert.ok(anyScope(tokens, 'string.quoted'), 'the "add" default is a string');
});
// MUTATION: delete `{ "include": "#range" }` from the top-level patterns.
// `0..500` reads as `0`, then `.` and `.500` as projections; the `..`
// assertion goes red and the range stops being a range.

test('G7d: a describe block is prose, and its port names are parameters', () => {
  const tokens = lex([
    'export def roaches(rate = 60) =',
    '    0',
    '',
    'describe roaches',
    '    "Cockroaches milling on a floor."',
    '    rate     "Rows born a second."',
    'spawn',
    '',
  ].join('\n'));

  assert.ok(scopesOfText(tokens, 'describe').includes('keyword.control.describe.rill'));
  assert.ok(scopesOfText(tokens, 'rate', 1).includes('variable.parameter.rill'),
    'a describe line names a port, not a statement head');
  // …and the block ENDS at the dedent, so `spawn` is a statement again.
  assert.ok(scopesOfText(tokens, 'spawn').includes('entity.name.function.rill'));
});
// MUTATION: change #describe-block's `while` to "^(?:.*)$". The block never
// ends, `spawn` is read as a describe line, and the last assertion goes red.

// ---------------------------------------------------------------------------
// G8 — literals.
// ---------------------------------------------------------------------------

test('G8: a duration is a number glued to a unit, and only four units exist', () => {
  const tokens = lex('fired | kick 20ms 340ms | delay 2m | sample 3f | ease 400ms\n');
  for (const [num, unit] of [['20', 'ms'], ['340', 'ms'], ['2', 'm'], ['3', 'f'], ['400', 'ms']]) {
    const t = tokens.find((x) => x.text === num && x.scopes.includes('constant.numeric.duration.rill'));
    assert.ok(t, `${num}${unit} did not lex as a duration`);
  }
  assert.ok(!anyScope(tokens, 'invalid.'), 'these are all real units');

  const bad = lex('sample 5x\n');
  assert.ok(anyScope(bad, 'invalid.illegal.duration-unit.rill'),
    '`5x` errors loud in the parser, so it is loud here');
});
// MUTATION: delete the second pattern of #duration (the invalid one). `5x`
// lexes as a number and a word, quietly, and the last assertion goes red.

test('G8b: a negative number is a number, and a lone `-` is a word', () => {
  const tokens = lex('gravity -9.8 | write plane.g\nlight arche l1 -\n');
  assert.ok(scopesOfText(tokens, '-9.8').includes('constant.numeric.rill'));
  assert.ok(scopesOfText(tokens, '-').includes('constant.language.unbind.rill'),
    'rill has no infix minus — subtraction is `sub`, so a lone `-` is the unbind sentinel');
});
// MUTATION: drop the `-?` from #number's match. `-9.8` lexes as the unbind
// sentinel followed by `9.8` and the first assertion goes red.

// ---------------------------------------------------------------------------
// G7e / G9 — the wrapped forms (the width canon, 2026-09-09).
//
// The printer breaks a line that runs past 88 columns: a chain into one stage
// per line with a leading `|`, a def signature into one port per line, an
// array into one element per line. Every one of those puts rill tokens in
// positions no corpus file held before, and a grammar that highlighted only
// the flat spellings would go yellow on `kernels/roaches.rill` the first time
// it was formatted.
// ---------------------------------------------------------------------------

test('G7e: a wrapped def signature keeps its pack, across the line breaks', () => {
  // This works because `#port-pack` is a begin/end rule and a nested one
  // MASKS its parent's `end` — so the `$` in `#def-signature`'s "(=)|$" is
  // never offered while the parens are open, and the context survives to the
  // `)` on line 5. That is a real property of how TextMate resolves rather
  // than an accident, and it is why the grammar needed no new rule; what it
  // needed was this gate, so the next edit to either `end` cannot quietly
  // take it away.
  const tokens = lex([
    'export def roaches(',
    '    rate = 60 (0..500),',
    '    blend = "add",',
    '    x: number = 1',
    ') on row =',
    '    0',
    '',
    'describe roaches',
    '    "One sentence."',
    '    rate  "How many."',
    'spawn',
    '',
  ].join('\n'));

  // A port on a line of its own is a PARAMETER, not a statement head — which
  // is what it looks like to every rule that anchors at `^`.
  assert.ok(scopesOfText(tokens, 'rate', 0).includes('variable.parameter.rill'));
  assert.ok(scopesOfText(tokens, 'blend').includes('variable.parameter.rill'));
  // …and the whole pack still scopes inside it: the range, the type, the
  // string default.
  assert.ok(scopesOfText(tokens, '..').includes('keyword.operator.range.rill'));
  assert.ok(scopesOfText(tokens, '500').includes('constant.numeric.rill'));
  assert.ok(scopesOfText(tokens, 'number').includes('entity.name.type.rill'));
  assert.ok(anyScope(tokens, 'string.quoted'), 'the "add" default is a string');
  // The `on row` after the closing paren is still the signature's plane.
  assert.ok(scopesOfText(tokens, 'on').includes('keyword.control.on.rill'));
  assert.ok(scopesOfText(tokens, 'row', 0).includes('entity.name.type.plane.rill'));
  // …and the body is out of it again.
  // (the first `0` is the range's minimum; the second is the body)
  assert.ok(!scopesOfText(tokens, '0', 1).some((s) => s.startsWith('meta.parameters')));

  // THE INTERACTION: a wrapped signature puts indented lines above a
  // `describe` block that never had any. The block still ends at a DEDENT, so
  // `spawn` is a statement again.
  assert.ok(scopesOfText(tokens, 'describe').includes('keyword.control.describe.rill'));
  assert.ok(scopesOfText(tokens, 'rate', 1).includes('variable.parameter.rill'));
  assert.ok(scopesOfText(tokens, 'spawn').includes('entity.name.function.rill'));
});
// MUTATIONS, two, one per half:
//   G7e         give #port-pack the end "\\)|$". The pack closes at the end
//               of the `def` line, the signature's own `$` closes behind it,
//               and every port below reads as a statement head — the first
//               four assertions go red.
//   G7e-dedent  loosen #describe-block's `while` to "^(?=[ \t]*\S|[ \t]*$)".
//               The block swallows `spawn` and the last assertion goes red.
//               (It takes G7d with it, which is honest: they are two gates
//               over one rule, and this one is the wrapped-signature case.)

test('G9: a broken chain and a broken span', () => {
  // The other two shapes, in the exact bytes the printer emits — a leading
  // `|` at the canon indent, and an array one element per line with its `]`
  // back in the stage's column.
  const tokens = lex([
    'plane.t',
    '    | over plane.life [',
    '        {l: 1.5, a: 0.08},',
    '        {l: 1.3, a: 0.12}',
    '    ]',
    '    | write plane.colour',
    '',
  ].join('\n'));

  assert.ok(!anyScope(tokens, 'invalid.'), 'nothing in a wrapped statement is illegal');
  // The continuation's `|` is a pipe and the word after it is the verb, even
  // though the line no longer starts at the margin.
  const pipes = tokens.filter((t) => t.text === '|');
  assert.equal(pipes.length, 2);
  for (const p of pipes) assert.ok(p.scopes.includes('keyword.operator.pipe.rill'));
  assert.ok(scopesOfText(tokens, 'over').includes('entity.name.function.rill'));
  assert.ok(scopesOfText(tokens, 'write').includes('entity.name.function.rill'));
  // The head is still a store, not a verb, on its own short line.
  assert.ok(scopesOfText(tokens, 'plane', 0).includes('support.class.plane.rill'));
  // A record element on a line of its own keeps its keys — `l` at the head of
  // an indented line is exactly what #operator-head would claim if the
  // record-key rule did not get there first.
  assert.ok(scopesOfText(tokens, 'l', 0).includes('variable.other.property.rill'));
  assert.ok(scopesOfText(tokens, '1.5').includes('constant.numeric.rill'));
  assert.ok(scopesOfText(tokens, '[').includes('punctuation.section.array.begin.rill'));
  assert.ok(scopesOfText(tokens, ']').includes('punctuation.section.array.end.rill'));
});
// MUTATION: drop the `(?<=[|{(])` alternative from #operator-head — the whole
// second pattern of it. `over` and `write` are no longer at the start of a
// line, so nothing scopes them as verbs and the two operator assertions go
// red. (At column 0 the first pattern hides this, which is why the fixture is
// the wrapped shape and not the flat one.)
