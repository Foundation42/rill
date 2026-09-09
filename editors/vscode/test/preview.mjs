#!/usr/bin/env node
// preview — render a .rill file in the terminal with the REAL theme colours.
//
//     node test/preview.mjs <file.rill> [dark|light]
//
// A scope list is a metric and metrics lie: `entity.name.function.rill` tells
// you nothing about whether the line reads. This loads VSCode's own Dark+ and
// Light+ (from the installed app, not a copy) and paints the file with them,
// so "does it look right" is a question you can answer without opening an
// editor — and so a scope chosen for its name can be caught being the wrong
// colour.
//
// It is a dev tool, not a gate. The gates are in grammar.test.mjs; this is
// the picture beside them.

import { readFile, access } from 'node:fs/promises';
import * as path from 'node:path';
import { loadGrammar, tokenize } from './tmgrammar.mjs';

// Where a VSCode install keeps the default themes. Dark+/Light+ are layered:
// `dark_plus` includes `dark_vs` and overrides it, so both are read in that
// order and a later rule of equal specificity wins — same as the editor.
const THEME_DIRS = [
  '/usr/share/code/resources/app/extensions/theme-defaults/themes',
  '/usr/lib/code/extensions/theme-defaults/themes',
  '/opt/visual-studio-code/resources/app/extensions/theme-defaults/themes',
  '/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/theme-defaults/themes',
  path.join(process.env.HOME || '', '.vscode-server/bin'),
];

async function themeDir() {
  for (const d of THEME_DIRS) {
    try { await access(path.join(d, 'dark_plus.json')); return d; } catch { /* next */ }
  }
  return null;
}

async function loadTheme(dir, files) {
  const rules = [];
  for (const f of files) {
    const d = JSON.parse(await readFile(path.join(dir, f), 'utf8'));
    for (const r of d.tokenColors || []) {
      const scopes = Array.isArray(r.scope) ? r.scope
        : typeof r.scope === 'string' ? r.scope.split(',').map((s) => s.trim())
          : [];
      for (const s of scopes) {
        if (r.settings && r.settings.foreground) rules.push({ scope: s, color: r.settings.foreground });
      }
    }
  }
  return rules;
}

/** The most specific rule that matches; ties go to the later rule. */
function colorFor(rules, scopes, fallback) {
  let best = fallback;
  let bestLen = -1;
  for (const s of scopes) {
    for (const r of rules) {
      if ((s === r.scope || s.startsWith(`${r.scope}.`)) && r.scope.length >= bestLen) {
        best = r.color;
        bestLen = r.scope.length;
      }
    }
  }
  return best;
}

function fg(hex) {
  const n = parseInt(hex.replace('#', '').slice(0, 6), 16);
  return `\x1b[38;2;${(n >> 16) & 255};${(n >> 8) & 255};${n & 255}m`;
}

const file = process.argv[2];
const which = process.argv[3] || 'dark';
if (!file) {
  console.error('usage: node test/preview.mjs <file.rill> [dark|light]');
  process.exit(2);
}

const dir = await themeDir();
if (!dir) {
  console.error('no VSCode install found to borrow themes from; add its path to THEME_DIRS');
  process.exit(2);
}

const rules = which === 'light'
  ? await loadTheme(dir, ['light_vs.json', 'light_plus.json'])
  : await loadTheme(dir, ['dark_vs.json', 'dark_plus.json']);
const fallback = which === 'light' ? '#000000' : '#D4D4D4';
const bg = which === 'light' ? '\x1b[48;2;255;255;255m' : '\x1b[48;2;31;31;31m';

const grammar = await loadGrammar();
const text = await readFile(file, 'utf8');
const lines = text.split('\n');
let out = '';
let cur = -1;
for (const t of tokenize(grammar, text)) {
  if (t.line !== cur) {
    if (cur !== -1) out += '\x1b[0m\n';
    cur = t.line;
    out += bg;
  }
  out += fg(colorFor(rules, t.scopes, fallback)) + lines[t.line].slice(t.startIndex, t.endIndex);
}
process.stdout.write(`${out}\x1b[0m\n`);
