'use strict';

// A `vscode` module, big enough to activate the extension and drive its three
// providers.
//
// WHY THIS EXISTS. The gates in client.test.mjs stop at `formatSource`, which
// returns a status. The thing that touches his file is one layer above that —
// the provider that turns a status into a `TextEdit` — and a bug there would
// pass every gate in that file while emptying a document. So the stub is not
// for coverage: it is so the LAST layer can be gated too.
//
// It is a stub, not a simulator. Everything it does is record the call.

const Module = require('node:module');

class Position {
  constructor(line, character) { this.line = line; this.character = character; }
  isBeforeOrEqual(o) { return this.line < o.line || (this.line === o.line && this.character <= o.character); }
}

class Range {
  constructor(start, end) { this.start = start; this.end = end; }
  contains(r) { return this.start.isBeforeOrEqual(r.start) && r.end.isBeforeOrEqual(this.end); }
}

class DocumentSymbol {
  constructor(name, detail, kind, range, selectionRange) {
    if (!range.contains(selectionRange)) {
      // VSCode throws on this, and a thrown outline is a silently empty one.
      throw new Error(`selectionRange outside range for '${name}'`);
    }
    Object.assign(this, { name, detail, kind, range, selectionRange, children: [] });
  }
}

class Diagnostic {
  constructor(range, message, severity) { Object.assign(this, { range, message, severity }); }
}

class TextEdit {
  constructor(range, newText) { Object.assign(this, { range, newText }); }
  static replace(range, newText) { return new TextEdit(range, newText); }
}

/** Everything the stub was told to do, for a test to read back. */
const log = {
  symbolProviders: [],
  formatProviders: [],
  commands: new Map(),
  diagnostics: new Map(),
  warnings: [],
  errors: [],
  status: [],
  disposables: [],
  settings: {},
};

function reset(settings) {
  log.symbolProviders.length = 0;
  log.formatProviders.length = 0;
  log.commands.clear();
  log.diagnostics.clear();
  log.warnings.length = 0;
  log.errors.length = 0;
  log.status.length = 0;
  log.disposables.length = 0;
  log.settings = settings || {};
}

// The SHIPPED defaults, read off the manifest rather than copied from it.
//
// This was a hardcoded duplicate until 2026-09-09, and the duplicate is what
// let `rill.format.args` be wrong in `package.json` while every gate that
// reads a setting stayed green: E6 asserted the unknown-name downgrade
// against a default this file made up. A gate over a value nobody ships is a
// gate over nothing.
const MANIFEST = require('../package.json');
const DEFAULTS = Object.fromEntries(
  Object.entries(MANIFEST.contributes.configuration.properties)
    .map(([key, spec]) => [key.replace(/^rill\./, ''), spec.default]),
);

const vscode = {
  Position,
  Range,
  DocumentSymbol,
  Diagnostic,
  TextEdit,
  SymbolKind: { Namespace: 2, Function: 11, Field: 7, Constant: 13, Variable: 12 },
  DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
  Uri: { file: (p) => ({ scheme: 'file', fsPath: p, toString: () => `file://${p}` }) },

  workspace: {
    textDocuments: [],
    getConfiguration: () => ({
      get: (key) => (key in log.settings ? log.settings[key] : DEFAULTS[key]),
    }),
    getWorkspaceFolder: () => undefined,
    onDidOpenTextDocument: () => ({ dispose() {} }),
    onDidSaveTextDocument: () => ({ dispose() {} }),
    onDidChangeTextDocument: () => ({ dispose() {} }),
    onDidCloseTextDocument: () => ({ dispose() {} }),
    onDidChangeConfiguration: () => ({ dispose() {} }),
  },

  languages: {
    createDiagnosticCollection: () => ({
      set: (uri, list) => log.diagnostics.set(uri.toString(), list),
      delete: (uri) => log.diagnostics.delete(uri.toString()),
      dispose() {},
    }),
    registerDocumentSymbolProvider: (_sel, p) => { log.symbolProviders.push(p); return { dispose() {} }; },
    registerDocumentFormattingEditProvider: (_sel, p) => { log.formatProviders.push(p); return { dispose() {} }; },
  },

  window: {
    activeTextEditor: undefined,
    showWarningMessage: (m) => log.warnings.push(m),
    showErrorMessage: (m) => log.errors.push(m),
    setStatusBarMessage: (m) => { log.status.push(m); return { dispose() {} }; },
    createOutputChannel: () => ({ appendLine: (m) => log.status.push(m), show() {}, dispose() {} }),
  },

  commands: {
    registerCommand: (id, fn) => { log.commands.set(id, fn); return { dispose() {} }; },
  },
};

/** A TextDocument over a string. */
function document(text, fsPath = '/tmp/x.rill') {
  const lines = text.split('\n');
  return {
    languageId: 'rill',
    uri: vscode.Uri.file(fsPath),
    lineCount: lines.length,
    getText: () => text,
    lineAt: (n) => ({
      text: lines[n],
      range: { end: new Position(n, lines[n].length) },
    }),
    positionAt: (offset) => {
      let rest = offset;
      for (let i = 0; i < lines.length; i += 1) {
        if (rest <= lines[i].length) return new Position(i, rest);
        rest -= lines[i].length + 1;
      }
      return new Position(lines.length - 1, lines[lines.length - 1].length);
    },
  };
}

/** Make `require('vscode')` resolve to the stub, once, for this process. */
let installed = false;
function install() {
  if (installed) return;
  installed = true;
  const realLoad = Module._load;
  Module._load = function load(request, parent, isMain) {
    if (request === 'vscode') return vscode;
    return realLoad.call(this, request, parent, isMain);
  };
}

module.exports = { vscode, log, reset, document, install };
