'use strict';

// symbols — the outline, from the text alone.
//
// No binary needed, which is the point: the outline is the feature you feel
// every day, so it must work on a machine where nothing is built yet.
//
// FOUR THINGS GO IN IT, and the first is the one that makes it worth having.
//
//   1. BANNERS. `matryoshka/kernels/roaches.rill` is the documented exemplar
//      and is roughly four-fifths prose, chaptered with `// ══ TITLE ══` and
//      sectioned with `// ── title ──`. Those rules are the file's structure —
//      they are how a reader navigates it — and a language server that
//      offered "no symbols" for it would be describing the wrong document.
//      So the banners are the outline's spine and everything else hangs off
//      them. Rejected: a flat list of defs, which for the exemplar is one
//      entry; and folding the prose away, which is the same mistake in
//      another dress.
//
//   2. `def` and `export def`, with their ports as children. An exported
//      definition's leading `describe` string becomes its detail, because
//      that sentence is the answer to "what is this" and it is already
//      written down.
//
//   3. `using … as :k` — a fold. It is file-scoped and everything downstream
//      reads through it, so it belongs near the top of the outline the way
//      it belongs near the top of the file.
//
//   4. `… as name` — a bound stream. Names are single-assignment and must be
//      defined before use, so parse order IS topological order: the outline's
//      order is the schedule's order, for free.

const KIND = {
  banner: 'namespace',
  def: 'function',
  port: 'field',
  fold: 'constant',
  stream: 'variable',
};

const NAME = '[A-Za-z_][A-Za-z0-9_]*(?:[-/][A-Za-z0-9_]+)*';

// A chapter rule and a section rule, in the house style. `═`/`=` outranks
// `─`/`—`/`-`, so a section nests under the chapter above it.
const BANNER_1 = new RegExp('^\\s*//\\s*[═=]{2,}\\s*(.*?)\\s*[═=]{2,}\\s*$');
const BANNER_2 = new RegExp('^\\s*//\\s*[─—-]{2,}\\s*(.*?)\\s*[─—-]{2,}\\s*$');

const DEF = new RegExp('^\\s*(?:(export)\\s+)?def\\s+(' + NAME + ')\\s*\\(');
const DESCRIBE = new RegExp('^\\s*describe\\s+(' + NAME + ')\\s*$');
const USING = new RegExp('^\\s*using\\s+(.*?)\\s+as\\s+(:' + NAME + ')\\s*$');
const AS_STREAM = new RegExp('\\bas\\s+(' + NAME + ')\\s*$');

/**
 * Strip the part of a line the tokenizer would drop, so a `//` inside a
 * describe string does not read as a comment and an `as` inside one does not
 * read as a binding.
 *
 * `//` opens a comment ONLY outside a string. That is the whole state machine
 * rill needs: there is no block comment, and no string spans a line — an
 * unterminated one is `unterminated string`, refused at the tokenizer.
 */
function code(line) {
  let out = '';
  let inString = false;
  for (let i = 0; i < line.length; i += 1) {
    const c = line[i];
    if (inString) {
      // A string's CONTENT is blanked rather than removed, so every column
      // after it still lands where it does in the file — the outline reports
      // positions by `indexOf` into this text, and a shortened line would
      // send the breadcrumb to the wrong character.
      if (c === '"') { inString = false; out += '"'; continue; }
      if (c === '\\' && i + 1 < line.length) { out += '  '; i += 1; continue; }
      out += ' ';
      continue;
    }
    if (c === '"') { inString = true; out += '"'; continue; }
    if (c === '/' && line[i + 1] === '/') break;
    out += c;
  }
  return out;
}

/** Split a def's port list on the commas that are not inside a nested group. */
function splitPorts(text) {
  const parts = [];
  let depth = 0;
  let start = 0;
  let inString = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (inString) {
      if (c === '\\') i += 1;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') { inString = true; continue; }
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) { parts.push([start, i]); start = i + 1; }
  }
  if (start < text.length) parts.push([start, text.length]);
  return parts;
}

/**
 * Read the whole outline out of `text`.
 *
 * Returns a tree of nodes:
 *   {name, detail, kind, line, endLine, col, endCol, children}
 * with 0-based lines and columns, so the caller builds ranges without
 * re-deriving anything.
 */
function outline(text) {
  const lines = text.split('\n');
  const root = { children: [] };
  // The open banners, innermost last. A banner runs until the next banner of
  // the same or higher rank, or the end of the file.
  const stack = [{ rank: 0, node: root }];
  const defs = new Map();

  const top = () => stack[stack.length - 1].node;
  const closeTo = (rank) => {
    while (stack.length > 1 && stack[stack.length - 1].rank >= rank) {
      stack.pop();
    }
  };
  const extend = (line) => {
    for (const frame of stack) if (frame.node !== root) frame.node.endLine = line;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    extend(i);

    const b1 = BANNER_1.exec(raw);
    const b2 = b1 ? null : BANNER_2.exec(raw);
    const banner = b1 || b2;
    if (banner) {
      const title = banner[1].trim();
      // A bare rule with no words is a divider, not a heading.
      if (title.length === 0) continue;
      const rank = b1 ? 1 : 2;
      closeTo(rank);
      const col = raw.indexOf('//');
      const node = {
        name: title,
        detail: '',
        kind: KIND.banner,
        line: i, col,
        endLine: i, endCol: raw.length,
        children: [],
      };
      top().children.push(node);
      stack.push({ rank, node });
      continue;
    }

    const src = code(raw);
    if (!src.trim()) continue;

    const def = DEF.exec(src);
    if (def) {
      const exported = Boolean(def[1]);
      const name = def[2];
      const open = src.indexOf('(', src.indexOf(name));
      // The signature ENDS AT THE NEWLINE — a `(` claims nothing across it —
      // so the port list is on this line or it is a parse error.
      const close = src.lastIndexOf(')');
      const inner = close > open ? src.slice(open + 1, close) : '';
      const node = {
        name,
        detail: exported ? 'export def' : 'def',
        kind: KIND.def,
        line: i, col: src.indexOf(exported ? 'export' : 'def'),
        endLine: i, endCol: raw.length,
        children: [],
      };
      for (const [a, b] of splitPorts(inner)) {
        const chunk = inner.slice(a, b);
        const m = new RegExp('^\\s*(' + NAME + ')').exec(chunk);
        if (!m) continue;
        const at = open + 1 + a + m[0].length - m[1].length;
        node.children.push({
          name: m[1],
          detail: chunk.trim().slice(m[1].length).trim(),
          kind: KIND.port,
          line: i, col: at,
          endLine: i, endCol: at + m[1].length,
          children: [],
        });
      }
      top().children.push(node);
      defs.set(name, node);
      continue;
    }

    const desc = DESCRIBE.exec(src);
    if (desc) {
      // The leading bare string of a describe block describes the DEFINITION
      // and comes first. Lift it onto the def, which is where a reader of the
      // outline is looking for it.
      const node = defs.get(desc[1]);
      for (let j = i + 1; j < lines.length; j += 1) {
        const t = lines[j].trim();
        if (!t) continue;
        const m = /^"((?:[^"\\]|\\.)*)"\s*$/.exec(t);
        if (node && m) node.detail = m[1];
        break;
      }
      continue;
    }

    const using = USING.exec(src);
    if (using) {
      top().children.push({
        name: using[2],
        detail: using[1],
        kind: KIND.fold,
        line: i, col: src.indexOf('using'),
        endLine: i, endCol: raw.length,
        children: [],
      });
      continue;
    }

    const bound = AS_STREAM.exec(src);
    if (bound && !/^\s*using\b/.test(src)) {
      const at = src.lastIndexOf(bound[1]);
      top().children.push({
        name: bound[1],
        detail: src.slice(0, src.indexOf(' as ')).trim(),
        kind: KIND.stream,
        line: i, col: at,
        endLine: i, endCol: at + bound[1].length,
        children: [],
      });
    }
  }

  extend(Math.max(0, lines.length - 1));
  return root.children;
}

module.exports = { outline, code, KIND };
