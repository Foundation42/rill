// tmgrammar — run the grammar the way VSCode runs it.
//
// This is a HARNESS I WROTE, and it is worth saying which part is mine. The
// tokenizer is not: `vscode-textmate` and `vscode-oniguruma` are the exact
// two packages VSCode itself loads to highlight a buffer, so what runs here
// is the real matcher against the real regex engine, not a re-implementation
// of either. What is mine is the twenty lines below that hand it a file and
// flatten the answer to one scope list per character.
//
// `vscode-tmgrammar-test` was the other candidate and was rejected for one
// reason: its unit form asserts scopes at annotated columns in a fixture,
// which is the right tool for a handful of hand-marked lines and the wrong
// one for the gate that matters here — EVERY character of all 47 corpus
// programs lands somewhere. That gate wants a per-character scope list, which
// is a function this file can return and that harness does not expose.

import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

// Both packages are CommonJS with a single webpacked entry point and no
// `exports` map, so `import * as` gives a namespace with the whole module on
// `.default` and nothing usable at the top level. `createRequire` gets the
// module VSCode itself gets.
const require = createRequire(import.meta.url);
const vsctm = require('vscode-textmate');
const oniguruma = require('vscode-oniguruma');

const here = path.dirname(fileURLToPath(import.meta.url));
export const EXT_ROOT = path.resolve(here, '..');

let registryPromise = null;

async function makeRegistry(grammarPath) {
  const wasmPath = require.resolve('vscode-oniguruma/release/onig.wasm');
  const wasm = await readFile(wasmPath);
  await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
  const raw = JSON.parse(await readFile(grammarPath, 'utf8'));
  return new vsctm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (s) => new oniguruma.OnigString(s),
    }),
    loadGrammar: async (scopeName) => (scopeName === 'source.rill' ? raw : null),
  });
}

/** The grammar, loaded once. `grammarPath` overrides for mutation tests. */
export async function loadGrammar(grammarPath) {
  const file = grammarPath || path.join(EXT_ROOT, 'syntaxes', 'rill.tmLanguage.json');
  if (!grammarPath) {
    registryPromise = registryPromise || makeRegistry(file);
    return (await registryPromise).loadGrammar('source.rill');
  }
  const registry = await makeRegistry(file);
  return registry.loadGrammar('source.rill');
}

/**
 * Tokenize `text`, one entry per token:
 *   {line, startIndex, endIndex, text, scopes}
 * Lines are 0-based; `scopes` includes the root `source.rill`.
 */
export function tokenize(grammar, text) {
  const out = [];
  let state = vsctm.INITIAL;
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const result = grammar.tokenizeLine(lines[i], state);
    for (const token of result.tokens) {
      out.push({
        line: i,
        startIndex: token.startIndex,
        endIndex: token.endIndex,
        text: lines[i].slice(token.startIndex, token.endIndex),
        scopes: token.scopes,
      });
    }
    state = result.ruleStack;
  }
  return out;
}

/**
 * Every scope carried by the character at `line:col` (0-based), or null when
 * nothing covers it.
 */
export function scopesAt(tokens, line, col) {
  for (const t of tokens) {
    if (t.line === line && col >= t.startIndex && col < t.endIndex) return t.scopes;
  }
  return null;
}

/** The token whose text is exactly `text`, nth occurrence (0-based). */
export function tokenNamed(tokens, text, nth = 0) {
  let seen = 0;
  for (const t of tokens) {
    if (t.text === text) {
      if (seen === nth) return t;
      seen += 1;
    }
  }
  return null;
}

/**
 * A scope beyond the container ones. `source.rill` is the root and every
 * `meta.*` is a container — neither says what a character IS, so a character
 * carrying only those is a character the grammar did not classify.
 */
export function isClassified(scopes) {
  if (!scopes) return false;
  return scopes.some((s) => s !== 'source.rill' && !s.startsWith('meta.'));
}
