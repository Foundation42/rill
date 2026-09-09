#!/usr/bin/env node
// mutate — apply each gate's named mutation and check the gate goes RED.
//
// A gate that cannot fail is decoration, and "I checked it fails" is only
// worth something if the check is a program. So the mutations are not prose
// here: each one is a substitution this file makes to a COPY of the tree,
// followed by a run of the one gate that names it. A mutation that leaves the
// suite green is reported as SURVIVED, and a survived mutation means the gate
// is watching nothing.
//
// The copy lives in `.mutant/` beside this extension, at the same depth as
// the real tree, and `RILL_SIBLINGS` points the corpus gate back at the real
// spindrift and matryoshka — a mutation that "bites" because the fixtures
// moved has measured nothing at all.
//
//     node test/mutate.mjs            all of them
//     node test/mutate.mjs G3 C1      just these

import { cp, rm, mkdir, readFile, writeFile, symlink } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.resolve(here, '..');
const MUTANT = path.join(EXT_ROOT, '.mutant');
const SIBLINGS = path.resolve(EXT_ROOT, '..', '..', '..');

const G = 'syntaxes/rill.tmLanguage.json';
const C = 'src/rillcli.js';
const S = 'src/symbols.js';
const L = 'language-configuration.json';
const P = 'package.json';

const GRAMMAR_TEST = 'test/grammar.test.mjs';
const CLIENT_TEST = 'test/client.test.mjs';
const CONFIG_TEST = 'test/config.test.mjs';
const EXT_TEST = 'test/extension.test.mjs';
const E2E_TEST = 'test/e2e.test.mjs';
const TESTS = [GRAMMAR_TEST, CLIENT_TEST, CONFIG_TEST, EXT_TEST, E2E_TEST];

/**
 * id      the gate it must break
 * file    what to edit
 * from/to the edit — `from` must appear exactly once, or the mutation is
 *         stale and is reported as such rather than silently doing nothing
 * test    which test file to run
 * name    the --test-name-pattern for the gate
 */
const MUTATIONS = [
  {
    id: 'G1', file: G, test: GRAMMAR_TEST, name: '^G1: ',
    why: 'no rule for a bare word — arguments, flags and write modes fall to the root scope',
    from: '    { "include": "#bare-word" }\n  ],', to: '  ],',
  },
  {
    id: 'G2', file: G, test: GRAMMAR_TEST, name: '^G2: ',
    why: '`#` leads a comment as well as `//` — the reading ruled out on 2026-08-25',
    from: '"match": "(//).*$",', to: '"match": "(//|#).*$",',
  },
  {
    id: 'G2b', file: G, test: GRAMMAR_TEST, name: '^G2b: ',
    why: '`/` stops joining two name characters, so a knob path shatters',
    from: '"match": "(\\\\.)([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*|\\\\d+)",',
    to: '"match": "(\\\\.)([A-Za-z_][\\\\w]*|\\\\d+)",',
  },
  {
    id: 'G3', file: G, test: GRAMMAR_TEST, name: '^G3: ',
    why: 'no fold rule — `:k` splits into a bare colon and a bare word',
    from: '    { "include": "#fold" },\n    { "include": "#duration" },',
    to: '    { "include": "#duration" },',
  },
  {
    id: 'G3b', file: G, test: GRAMMAR_TEST, name: '^G3b: ',
    why: 'a kwarg colon may be separated from its name — the mis-pairing `colonOpensFold` exists to prevent',
    from: '"match": "([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)(:)(?!:)",',
    to: '"match": "([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)\\\\s*(:)(?!:)",',
  },
  {
    id: 'G4', file: G, test: GRAMMAR_TEST, name: '^G4: ',
    why: 'the `$` sigil is split off as punctuation instead of staying inside the name',
    from: '{ "match": "\\\\$[A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*", "name": "entity.name.tag.channel.rill" },',
    to: '{ "match": "(\\\\$)([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)", "captures": { "1": { "name": "punctuation.definition.variable.rill" }, "2": { "name": "entity.name.tag.channel.rill" } } },',
  },
  {
    id: 'G5', file: G, test: GRAMMAR_TEST, name: '^G5: ',
    why: 'no two-word rule — the sub-op of `rbf through` reads as an argument',
    from: '    { "include": "#operator-head-two-word" },\n', to: '\n',
  },
  {
    id: 'G5b', file: G, test: GRAMMAR_TEST, name: '^G5b: ',
    why: 'a GENERIC two-word rule — `along track` reads as a verb, like every curve-drawing kernel in matryoshka',
    from: '"match": "^([ \\\\t]*)(rbf)([ \\\\t]+)([A-Za-z_][\\\\w]*)",',
    to: '"match": "^([ \\\\t]*)([A-Za-z_][\\\\w]*)([ \\\\t]+)([A-Za-z_][\\\\w]*)",',
    also: [{
      from: '"match": "(?<=[|{(])([ \\\\t]*)(rbf)([ \\\\t]+)([A-Za-z_][\\\\w]*)",',
      to: '"match": "(?<=[|{(])([ \\\\t]*)([A-Za-z_][\\\\w]*)([ \\\\t]+)([A-Za-z_][\\\\w]*)",',
    }],
  },
  {
    id: 'G6', file: G, test: GRAMMAR_TEST, name: '^G6: ',
    why: 'the colon adjacency law goes — `pack:horns` reads its colon as a fold',
    from: '"match": "(?:^|(?<=[\\\\s(\\\\[{,|]))(:[$@#^]?[A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)",',
    to: '"match": "(:[$@#^]?[A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)",',
    // Both halves, because either alone is masked by the other: #record-key
    // matches EARLIER in the line and eats `pack:` before the fold rule is
    // ever offered the colon. That masking is the design working, and it is
    // why this mutation is a pair rather than a single edit.
    also: [{ from: '    { "include": "#record-key" },\n', to: '' }],
  },
  {
    id: 'G6-loc', file: G, test: GRAMMAR_TEST, name: '^G6: ',
    why: 'no locator rule — `/tmp/loop.wav` shatters into a stray slash, a joined name and a projection',
    from: '    { "include": "#locator" },\n', to: '',
  },
  {
    id: 'G7', file: G, test: GRAMMAR_TEST, name: '^G7: ',
    why: 'the three stores get no scope of their own — a path head reads as an ordinary word',
    from: '    { "include": "#path-head" },\n', to: '',
  },
  {
    id: 'G7-indent', file: G, test: GRAMMAR_TEST, name: '^G7: ',
    why: 'head position stops excluding a path — an INDENTED path-headed statement goes yellow',
    from: '(?![\\\\w.:/-])",\n          "captures": {\n            "2": { "name": "entity.name.function.rill" }\n          }\n        },\n        {\n          "match": "(?<=[|{(])',
    to: '",\n          "captures": {\n            "2": { "name": "entity.name.function.rill" }\n          }\n        },\n        {\n          "match": "(?<=[|{(])',
  },
  {
    id: 'G7b', file: G, test: GRAMMAR_TEST, name: '^G7b: ',
    why: 'the signature ends at the newline instead of at the `=` — a one-line def\'s body is read as signature',
    from: '"end": "(=)|$",', to: '"end": "$",',
  },
  {
    id: 'G7c', file: G, test: GRAMMAR_TEST, name: '^G7c: ',
    why: 'no range rule inside a pack — `0..500` stops being a range',
    from: '        { "include": "#range" },\n        { "include": "#fold" },',
    to: '        { "include": "#fold" },',
  },
  {
    id: 'G7d', file: G, test: GRAMMAR_TEST, name: '^G7d: ',
    why: 'a describe block never dedents — the statements after it are read as prose',
    // ANCHORED ON THE RULE, not on the pattern. `layout` (2026-09-09) gave a
    // second block the same dedent `while`, so a bare anchor matched twice and
    // the runner reported this stale rather than mutating the wrong block —
    // three gates watching nothing until the anchors were widened. The
    // subject's scope is what tells the two apart: `describe` names a def,
    // `layout` names the document.
    from: '"3": { "name": "entity.name.function.rill" }\n      },\n      "while": "^(?=[ \\\\t]+\\\\S|[ \\\\t]*$)",',
    to: '"3": { "name": "entity.name.function.rill" }\n      },\n      "while": "^(?=.*$)",',
  },
  {
    id: 'G8', file: G, test: GRAMMAR_TEST, name: '^G8: ',
    why: 'an unknown duration unit lexes quietly instead of loud',
    from: '          "match": "(?<![\\\\w$@#^])-?\\\\d+(?:\\\\.\\\\d+)?[A-Za-z]+(?![\\\\w.-])",\n          "name": "invalid.illegal.duration-unit.rill"',
    to: '          "match": "(?<![\\\\w$@#^])-?\\\\d+(?:\\\\.\\\\d+)?zzzz(?![\\\\w.-])",\n          "name": "invalid.illegal.duration-unit.rill"',
  },
  {
    id: 'G8b', file: G, test: GRAMMAR_TEST, name: '^G8b: ',
    why: 'a number may not be negative — `-9.8` reads as the unbind sentinel and a number',
    from: '"match": "(?<![\\\\w$@#^])-?\\\\d+(?:\\\\.\\\\d+)?(?:[eE][-+]?\\\\d+)?(?![\\\\w]|\\\\.\\\\d)",',
    to: '"match": "(?<![\\\\w$@#^])\\\\d+(?:\\\\.\\\\d+)?(?:[eE][-+]?\\\\d+)?(?![\\\\w]|\\\\.\\\\d)",',
  },

  {
    id: 'C1', file: C, test: CLIENT_TEST, name: '^C1: ',
    why: 'the naive shape — a missing binary\'s empty stdout is trusted, and the document is emptied',
    from: "    return { status: 'missing', detail: res.spawnError.message };",
    to: "    return { status: 'formatted', text: res.stdout };",
  },
  {
    id: 'C2', file: C, test: CLIENT_TEST, name: '^C2: ',
    why: 'guard 3 removed — exit 0 with nothing back is believed',
    from: "  if (source.trim().length > 0 && res.stdout.trim().length === 0) {",
    to: "  if (false) {",
  },
  {
    id: 'C3', file: C, test: CLIENT_TEST, name: '^C3: ',
    why: 'guard 4 removed — a formatter that deletes the prose is believed',
    from: '  if (after < before) {', to: '  if (after < 0) {',
  },
  {
    id: 'C4', file: C, test: CLIENT_TEST, name: '^C4: ',
    why: '"I do not know this command" reads as a failure instead of as "not shipped yet"',
    from: "  if (res.code === EX_USAGE) {\n    return { status: 'unsupported', detail: (res.stderr || res.stdout).trim() };\n  }\n  if (res.code === EX_DATAERR) {",
    to: "  if (res.code === EX_DATAERR) {",
  },
  {
    id: 'C5', file: C, test: CLIENT_TEST, name: '^C5: ',
    why: 'a parse error pops a formatting message the squiggle already said',
    from: "  if (res.code === EX_DATAERR) {\n    return { status: 'parse-error', detail: (res.stderr || res.stdout).trim() };\n  }\n",
    to: '',
  },
  {
    id: 'C6', file: C, test: CLIENT_TEST, name: '^C6: ',
    why: 'an already-formatted file is rewritten anyway, costing an undo step for nothing',
    from: "  if (res.stdout === source) return { status: 'unchanged' };\n", to: '',
  },
  {
    id: 'C8', file: C, test: CLIENT_TEST, name: '^C8: ',
    why: 'the probe stops checking that the comment came back',
    from: "  if (!res.stdout.includes('rill vscode probe')) {", to: '  if (false) {',
  },
  {
    id: 'C9c', file: C, test: CLIENT_TEST, name: '^C9c: ',
    why: 'an unreadable reply reads as all-clear, so a crashed checker wipes real squiggles',
    from: "    if (res.code === 0) return { status: 'ok', diagnostics: [] };\n    return { status: 'unreadable', detail: (res.stderr || res.stdout).trim() || `exit ${res.code}` };",
    to: "    return { status: 'ok', diagnostics: [] };",
  },
  {
    id: 'C9d', file: C, test: CLIENT_TEST, name: '^C9d: ',
    why: 'a diagnostic with no line is given line 1 instead of being dropped',
    from: '      if (!Number.isFinite(line) || line < 1) continue;',
    to: '      const line2 = Number.isFinite(line) && line >= 1 ? line : 1;',
    also: [{ from: '        line,\n        col:', to: '        line: line2,\n        col:' }],
  },
  {
    id: 'C10', file: S, test: CLIENT_TEST, name: '^C10: ',
    why: 'the describe block\'s leading sentence is not lifted onto the def',
    from: '        if (node && m) node.detail = m[1];', to: '        if (false) node.detail = m[1];',
  },
  {
    id: 'C10b', file: S, test: CLIENT_TEST, name: '^C10b: ',
    why: 'banners are not symbols — the exemplar outlines to two entries for 250 lines',
    from: '    const banner = b1 || b2;', to: '    const banner = null;',
  },
  {
    id: 'C10c', file: S, test: CLIENT_TEST, name: '^C10c: ',
    why: '`//` inside a describe string is read as a comment, halving the sentence',
    from: "    if (c === '\"') { inString = true; out += '\"'; continue; }\n",
    to: '',
  },

  {
    id: 'E2', file: 'src/extension.js', test: EXT_TEST, name: '^E2: ',
    why: 'a symbol\'s children are never attached — every def outlines with no ports',
    from: '    symbol.children = toSymbols(n.children, document);\n', to: '',
  },
  {
    id: 'E3', file: 'src/extension.js', test: EXT_TEST, name: '^E3: ',
    why: 'the unavailable branch edits the document anyway — an empty file on the first save after install',
    from: "      say(`format:${probe.reason}:${binary}`, why, probe.reason === 'mangled');\n      return [];",
    to: "      say(`format:${probe.reason}:${binary}`, why, probe.reason === 'mangled');\n      return [vscode.TextEdit.replace(new vscode.Range(document.positionAt(0), document.positionAt(document.getText().length)), '')];",
  },
  {
    id: 'E5', file: 'src/extension.js', test: EXT_TEST, name: '^E5: ',
    why: 'the replace range stops one character short — the last byte of the file survives every format',
    from: '          document.positionAt(source.length),', to: '          document.positionAt(source.length - 1),',
  },
  {
    id: 'E6', file: 'src/extension.js', test: EXT_TEST, name: '^E6: ',
    why: 'an unknown name is an error — every host word in every kernel goes red',
    from: "    if (d.code === 'unknown_operator') {", to: '    if (false) {',
  },
  {
    id: 'E7', file: 'src/extension.js', test: EXT_TEST, name: '^E7: ',
    why: 'the squiggle stops at the first dot — five characters of a twenty-character path',
    from: "  const token = new RegExp(`^${NAME}(?:\\\\.${NAME})*|^[^\\\\s]`).exec(rest);",
    to: "  const token = new RegExp(`^${NAME}|^[^\\\\s]`).exec(rest);",
  },
  {
    id: 'L1', file: P, test: CONFIG_TEST, name: '^L1: ',
    why: 'two spaces — the editor fights the printer on every save',
    from: '"editor.tabSize": 4,', to: '"editor.tabSize": 2,',
  },
  {
    id: 'L2', file: L, test: CONFIG_TEST, name: '^L2: ',
    why: 'a block comment is offered, in a language that has none',
    from: '"lineComment": "//"', to: '"lineComment": "//", "blockComment": ["/*", "*/"]',
  },
  {
    id: 'L3', file: L, test: CONFIG_TEST, name: '^L3: ',
    why: 'the word pattern drops the sigils — `:k` selects as `k`',
    from: '"wordPattern": "([:$@#^]?[A-Za-z_]', to: '"wordPattern": "([A-Za-z_]',
  },
  {
    id: 'L4', file: L, test: CONFIG_TEST, name: '^L4: ',
    why: 'a describe block does not indent, so its first line lands in the left margin and ends the block',
    from: '|describe\\\\s+[A-Za-z_][\\\\w-]*\\\\s*$', to: '',
  },
  {
    id: 'L6', file: P, test: CONFIG_TEST, name: '^L6: ',
    why: 'the manifest points at a grammar that is not there — VSCode logs it once and highlights nothing',
    from: '"path": "./syntaxes/rill.tmLanguage.json"', to: '"path": "./syntaxes/gone.json"',
  },
  {
    id: 'G7e', file: G, test: GRAMMAR_TEST, name: '^G7e: ',
    why: 'the port pack does not survive a line break — every wrapped port reads as a statement head',
    from: '      "name": "meta.parameters.rill",\n      "begin": "\\\\(",\n      "end": "\\\\)",',
    to: '      "name": "meta.parameters.rill",\n      "begin": "\\\\(",\n      "end": "\\\\)|$",',
  },
  {
    id: 'G7e-dedent', file: G, test: GRAMMAR_TEST, name: '^G7e: ',
    why: 'a describe block does not need an indent to continue — the wrapped signature above it makes that look plausible',
    // Same widening as G7d, same reason.
    from: '"3": { "name": "entity.name.function.rill" }\n      },\n      "while": "^(?=[ \\\\t]+\\\\S|[ \\\\t]*$)",',
    to: '"3": { "name": "entity.name.function.rill" }\n      },\n      "while": "^(?=[ \\\\t]*\\\\S|[ \\\\t]*$)",',
  },
  {
    id: 'G9', file: G, test: GRAMMAR_TEST, name: '^G9: ',
    why: 'head position after a `|` goes — a broken chain has no verbs, only words',
    // The keyword list in this lookahead gained `layout` (2026-09-09) and the
    // anchor went to ZERO matches — the other half of the same staleness G7d
    // hit, and the reason a mutation's `from` must be re-read whenever the
    // rule it quotes is edited.
    from: '        {\n          "match": "(?<=[|{(])([ \\\\t]*)(?!(?:def|export|describe|layout|using|use|also|as|true|false)(?![\\\\w-]))([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)(?![\\\\w.:/-])",\n          "captures": {\n            "2": { "name": "entity.name.function.rill" }\n          }\n        }\n',
    to: '',
    also: [{ from: '          }\n        },\n      ]\n    },\n\n    "def-signature"', to: '          }\n        }\n      ]\n    },\n\n    "def-signature"' }],
  },
  {
    id: 'C10d', file: S, test: CLIENT_TEST, name: '^C10d: ',
    why: 'the port list is read from the def\'s own line again — a wrapped signature outlines with no ports',
    from: '  for (let j = first; j < lines.length; j += 1) {',
    to: '  for (let j = first; j < first + 1; j += 1) {',
  },
  {
    id: 'L7', file: L, test: CONFIG_TEST, name: '^L7: ',
    why: 'the `) =` that closes a wrapped signature does not indent — the body is typed in the left margin, where a def\'s dedent rule ends it',
    from: '|\\\\)(?:\\\\s+on\\\\s+[A-Za-z_]\\\\w*)?\\\\s*=\\\\s*$', to: '',
  },
  {
    id: 'L8', file: L, test: CONFIG_TEST, name: '^L8: ',
    why: 'Enter inside a broken chain indents — the chain steps right a stage at a time and the save steps it back',
    from: '"beforeText": "^(\\\\s*)\\\\|\\\\s.*$",\n      "action": { "indent": "none", "appendText": "| " }',
    to: '"beforeText": "^(\\\\s*)\\\\|\\\\s.*$",\n      "action": { "indent": "indent", "appendText": "| " }',
  },
  {
    id: 'E8', file: 'src/extension.js', test: EXT_TEST, name: '^E8: ',
    why: 'Format Document on a spray kernel does nothing, silently, for ever — the state the extension shipped in this morning',
    from: "        say(\n          `format:parse:${binary}`,\n          'the file did not parse, so it was left alone. If it is a spray kernel, add --host-row to rill.format.args.',\n        );\n",
    to: '',
  },
  // ── the manifest's DEFAULTS, which nothing could reach until 2026-09-09 ──
  //
  // `test/fake-vscode.cjs` used to hold its own copy of them, so every gate
  // that read a setting read a value this repo made up rather than the value
  // it ships. Both of these now bite because the fake derives its defaults
  // from `package.json`.
  {
    id: 'X4', file: P, test: E2E_TEST, name: '^X4: ',
    why: 'the shipped format args say `format` where the binary says `fmt` — silently off on every machine',
    from: '            "fmt",', to: '            "format",',
  },
  {
    id: 'E6b', file: P, test: EXT_TEST, name: '^E6: ',
    why: 'the shipped unknownNames default is `error` — every host word in every kernel opens as a red squiggle',
    from: '"default": "warning",', to: '"default": "error",',
  },
  {
    id: 'L9', file: 'snippets/rill.json', test: CONFIG_TEST, name: '^L9: ',
    why: 'the spray package teaches a 149-column signature the first save reflows',
    from: '      "export def ${1:name}(",\n      "    rate = ${3:60} (0..500),",\n      "    speed = ${4:0.15} (0..5),",\n      "    spread = ${5:0.35} (0..3),",\n      "    life = ${6:14000} (16..60000),",\n      "    capacity = ${7:4096} (1..65536),",\n      "    blend = \\"${8|add,alpha|}\\"",\n      ") =",',
    to: '      "export def ${1:name}(rate = ${3:60} (0..500), speed = ${4:0.15} (0..5), spread = ${5:0.35} (0..3), life = ${6:14000} (16..60000), capacity = ${7:4096} (1..65536), blend = \\"${8|add,alpha|}\\") =",',
  },
  // ── the two spellings a canvas needs, 2026-09-09 ────────────────────────
  //
  // `layout` puts node positions IN the document; a shaped hole lets the
  // document hold a node nothing is wired to yet. Both anchors below quote
  // enough of their own rule to be unique — `layout` shares `describe`'s
  // dedent `while`, which is what went stale here the first time.
  {
    id: 'G7f', file: G, test: GRAMMAR_TEST, name: '^G7f: ',
    why: 'no layout rule — `layout` reads as an operator head, its subject as an argument, and every node key as a statement of its own',
    from: '    { "include": "#layout-block" },\n', to: '',
  },
  {
    id: 'G7f-dedent', file: G, test: GRAMMAR_TEST, name: '^G7f: ',
    why: 'a layout block never dedents — the statement after it is read as another node position',
    from: '"3": { "name": "entity.name.namespace.rill" }\n      },\n      "while": "^(?=[ \\\\t]+\\\\S|[ \\\\t]*$)",',
    to: '"3": { "name": "entity.name.namespace.rill" }\n      },\n      "while": "^(?=.*$)",',
  },
  {
    id: 'G7g', file: G, test: GRAMMAR_TEST, name: '^G7g: ',
    why: 'the hole sigil claims the `?` a shape literal already spent — `expect {id?: string}` reads its optional field as a hole',
    from: '"match": "(\\\\?)(?![:])([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)?",',
    to: '"match": "(\\\\?)([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)?",',
  },
  {
    id: 'G7g-list', file: G, test: GRAMMAR_TEST, name: '^G7g: ',
    why: 'the shape vocabulary is hard-coded to the eight built-ins — a host type stops being a shape the grammar can see',
    from: '"match": "(\\\\?)(?![:])([A-Za-z_][\\\\w]*(?:[-/][\\\\w]+)*)?",',
    to: '"match": "(\\\\?)(?![:])(number|boolean|string|record|bytes|array|duration|any)?",',
  },
  {
    id: 'C10-hole', file: S, test: CLIENT_TEST, name: '^C10: ',
    why: 'a `using` body must start with a name — every shaped hole drops out of the outline',
    from: "const USING = new RegExp('^\\\\s*using\\\\s+(.*?)\\\\s+as\\\\s+(:' + NAME + ')\\\\s*$');",
    to: "const USING = new RegExp('^\\\\s*using\\\\s+([A-Za-z].*?)\\\\s+as\\\\s+(:' + NAME + ')\\\\s*$');",
  },
];

function sh(cmd, args, opts) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { ...opts, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve({ code, out }));
  });
}

async function freshMutant() {
  await rm(MUTANT, { recursive: true, force: true });
  await mkdir(MUTANT, { recursive: true });
  for (const entry of ['src', 'test', 'syntaxes', 'snippets', 'package.json', 'language-configuration.json']) {
    await cp(path.join(EXT_ROOT, entry), path.join(MUTANT, entry), { recursive: true });
  }
  await rm(path.join(MUTANT, '.mutant'), { recursive: true, force: true });
  await symlink(path.join(EXT_ROOT, 'node_modules'), path.join(MUTANT, 'node_modules'), 'dir');
}

async function apply(file, edits) {
  const full = path.join(MUTANT, file);
  let text = await readFile(full, 'utf8');
  for (const { from, to } of edits) {
    const n = text.split(from).length - 1;
    if (n !== 1) return `stale mutation: '${from.slice(0, 60)}…' appears ${n} times in ${file}`;
    text = text.replace(from, to);
  }
  await writeFile(full, text);
  return null;
}

async function main() {
  const wanted = process.argv.slice(2);
  const chosen = wanted.length
    ? MUTATIONS.filter((m) => wanted.includes(m.id))
    : MUTATIONS;
  if (wanted.length && chosen.length !== wanted.length) {
    const have = new Set(chosen.map((m) => m.id));
    console.error(`no such mutation: ${wanted.filter((w) => !have.has(w)).join(', ')}`);
    process.exit(2);
  }

  // The baseline. A mutation run against a red suite measures nothing, so
  // this is the first thing checked and the run stops if it is not green.
  const base = await sh(process.execPath, ['--test', ...TESTS], { cwd: EXT_ROOT });
  if (base.code !== 0) {
    console.error('the suite is not green to begin with; nothing here would mean anything\n');
    console.error(base.out.slice(-4000));
    process.exit(2);
  }
  console.log('baseline: green\n');

  let survived = 0;
  let stale = 0;
  for (const m of chosen) {
    await freshMutant();
    const edits = [{ from: m.from, to: m.to }, ...(m.also || [])];
    const problem = await apply(m.file, edits);
    if (problem) {
      console.log(`  STALE   ${m.id.padEnd(5)} ${problem}`);
      stale += 1;
      continue;
    }
    const res = await sh(
      process.execPath,
      ['--test', '--test-name-pattern', m.name, m.test],
      // RILL_ROOT as well as RILL_SIBLINGS: the mutant tree is one level
      // deeper than the real one, so the e2e suite's walk up to the rill
      // checkout (for the binary and the corpus) lands in `editors/`.
      { cwd: MUTANT, env: { ...process.env, RILL_SIBLINGS: SIBLINGS, RILL_ROOT: path.resolve(EXT_ROOT, '..', '..') } },
    );
    if (res.code === 0) {
      console.log(`  SURVIVED ${m.id.padEnd(5)} ${m.why}`);
      console.log('           the gate is watching nothing.');
      survived += 1;
    } else {
      console.log(`  bit     ${m.id.padEnd(5)} ${m.why}`);
    }
  }
  await rm(MUTANT, { recursive: true, force: true });

  console.log(`\n${chosen.length} mutations, ${chosen.length - survived - stale} bit, ${survived} survived, ${stale} stale`);
  process.exit(survived + stale === 0 ? 0 : 1);
}

main();
