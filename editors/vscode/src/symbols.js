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
//
// WHAT IS DELIBERATELY NOT IN IT: a `layout` block (2026-09-09). The outline
// answers "how do I navigate this document", and the layout block is the one
// part of a rill file a person never reads — it is a coordinate table a
// canvas writes and a canvas reads. Its keys are node instance names, so
// putting them in would fill the outline with `mul1`, `write1`, `add1` and
// bury the four things above. RECORDED, NOT BUILT. Trigger: an editor that
// wants to jump from the outline to a node's position, which is the reverse
// of the direction anyone has asked for.

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
 * A def's port list, which may span several lines.
 *
 * Returns `{text, at, endLine}`: the interior of the parens with every line
 * break turned into a space, a position `{line, col}` for each character of
 * it, and the line the `)` closed on. The per-character map is what lets a
 * port report the line it is really on — deriving it afterwards would mean
 * re-finding the port in the file, which is the same scan done twice.
 *
 * Depth counting with the strings skipped, exactly as `splitPorts` does it: a
 * `(` inside a default's string is not an opener, and a range's `(0..500)` is
 * a nested pair that must not be mistaken for the end of the list.
 */
function signature(lines, first, firstCode, open) {
  const chars = [];
  const at = [];
  let depth = 0;
  let inString = false;
  for (let j = first; j < lines.length; j += 1) {
    const s = j === first ? firstCode : code(lines[j]);
    for (let k = j === first ? open : 0; k < s.length; k += 1) {
      const c = s[k];
      if (inString) {
        if (c === '\\') { chars.push(c, s[k + 1] || ' '); at.push({ line: j, col: k }, { line: j, col: k + 1 }); k += 1; continue; }
        if (c === '"') inString = false;
      } else if (c === '"') inString = true;
      else if (c === '(') {
        depth += 1;
        if (depth === 1) continue; // the opener itself is not in the interior
      } else if (c === ')') {
        depth -= 1;
        if (depth === 0) return { text: chars.join(''), at, endLine: j };
      }
      chars.push(c);
      at.push({ line: j, col: k });
    }
    // A line break inside the parens separates two ports exactly as a space
    // does; the comma is still the separator `splitPorts` looks for.
    chars.push(' ');
    at.push({ line: j, col: s.length });
  }
  // Unclosed — a signature half typed. Report no ports rather than guessing,
  // and end where it started so the outline does not swallow the file.
  return { text: '', at: [], endLine: first };
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
      // A SIGNATURE MAY WRAP (2026-09-09). The parser accepts a newline inside
      // the parens and the printer puts one port on its own line whenever the
      // flat form runs past 88 columns — which `kernels/roaches.rill`, the
      // exemplar this outline exists for, does at 234 columns. Reading only
      // this line outlines that file's one exported definition with NO ports.
      const sig = signature(lines, i, src, open);
      const inner = sig.text;
      const node = {
        name,
        detail: exported ? 'export def' : 'def',
        kind: KIND.def,
        line: i, col: src.indexOf(exported ? 'export' : 'def'),
        endLine: sig.endLine, endCol: lines[sig.endLine].length,
        children: [],
      };
      for (const [a, b] of splitPorts(inner)) {
        const chunk = inner.slice(a, b);
        const m = new RegExp('^\\s*(' + NAME + ')').exec(chunk);
        if (!m) continue;
        // Each port reports the line and the column it is ACTUALLY on, which
        // is a line of its own once the signature wraps — so the breadcrumb
        // jumps to the port rather than to the `def` above it.
        const at = sig.at[a + m[0].length - m[1].length];
        node.children.push({
          name: m[1],
          detail: chunk.trim().slice(m[1].length).trim(),
          kind: KIND.port,
          line: at.line, col: at.col,
          endLine: at.line, endCol: at.col + m[1].length,
          children: [],
        });
      }
      top().children.push(node);
      defs.set(name, node);
      // Skip what the signature took. Without this every port line is offered
      // to the rules below, and one holding the word `as` in a string default
      // would outline as a bound stream.
      i = sig.endLine;
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
