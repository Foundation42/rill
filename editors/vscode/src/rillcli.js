'use strict';

// rillcli — everything that talks to the rill binary, and NOTHING that talks
// to VSCode.
//
// The split is here so the one gate that matters can run without an editor:
// `formatSource` must return "no edit" when the binary is missing, and a unit
// test can only assert that if calling it does not need a window. See
// test/client.test.mjs, mutation 3.
//
// THE RULE THIS FILE EXISTS TO KEEP: never hand back a formatted result you
// did not actually get. Four ways that can go wrong and four guards, each
// named below. A formatter that eats `matryoshka/kernels/roaches.rill` has
// deleted the only documentation of the thing it just edited — four-fifths of
// that file is `//` lines — so the comment count is checked on the way back
// and a shortfall is loud, not a shrug.

const { spawn } = require('node:child_process');
const path = require('node:path');

/// How long a call may take before it is killed. An editor that hangs on a
/// format is worse than one that cannot format.
const TIMEOUT_MS = 5000;

/// sysexits, which is what the contract asks the binary to speak. 64 says
/// "I do not understand this command line" and is the one the client must
/// tell apart from the rest: it means the feature is unavailable, not that
/// the file is wrong.
const EX_USAGE = 64;
const EX_DATAERR = 65;

/// The probe program. A comment-only file is valid rill (zero statements) and
/// it tests the exact property the formatter is trusted for: comments come
/// back. A binary that answers this is one whose `fmt` can be believed.
const PROBE = '// rill vscode probe\n';

/**
 * Run the binary with `input` on stdin.
 *
 * Resolves to {code, stdout, stderr, spawnError} and never rejects: every
 * failure mode is a value the caller has to decide about, and an exception
 * here would become a wall of errors in the editor, which is the thing the
 * brief rules out.
 */
function run(binary, args, input, opts = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(binary, args, {
        cwd: opts.cwd,
        env: opts.env || process.env,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
    } catch (err) {
      resolve({ code: null, stdout: '', stderr: '', spawnError: err });
      return;
    }

    let stdout = '';
    let stderr = '';
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };

    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch { /* already gone */ }
      finish({ code: null, stdout, stderr, spawnError: new Error('timed out') });
    }, opts.timeoutMs || TIMEOUT_MS);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    // ENOENT arrives here, not from spawn(): a missing binary is an event.
    child.on('error', (err) => finish({ code: null, stdout, stderr, spawnError: err }));
    child.on('close', (code) => finish({ code, stdout, stderr, spawnError: null }));

    child.stdin.on('error', () => { /* the child died before reading; `close` reports it */ });
    child.stdin.end(input);
  });
}

/**
 * Resolve the configured binary path.
 *
 * A bare name is left alone so `spawn` looks it up on PATH; anything with a
 * separator is resolved against the workspace folder, so `./zig-out/bin/rill`
 * means what it looks like it means.
 */
function resolveBinary(configured, workspaceDir) {
  const raw = (configured || 'rill').trim();
  if (!raw) return 'rill';
  if (path.isAbsolute(raw)) return raw;
  if (raw.includes('/') || raw.includes('\\')) {
    return workspaceDir ? path.resolve(workspaceDir, raw) : raw;
  }
  return raw;
}

function countCommentLines(text) {
  let n = 0;
  for (const line of text.split('\n')) if (/^\s*\/\//.test(line)) n += 1;
  return n;
}

/**
 * Ask the binary whether it speaks `fmt`.
 *
 * Returns {ok: true} or {ok: false, reason, detail}. `reason` is one of
 * 'missing' | 'usage' | 'mangled' | 'failed', which is enough for the caller
 * to say one clear sentence and stop asking.
 */
async function probeFormat(binary, args, opts = {}) {
  const res = await run(binary, args, PROBE, opts);
  if (res.spawnError) {
    return { ok: false, reason: 'missing', detail: res.spawnError.message };
  }
  if (res.code === EX_USAGE) {
    return { ok: false, reason: 'usage', detail: (res.stderr || res.stdout).trim() };
  }
  if (res.code !== 0) {
    return { ok: false, reason: 'failed', detail: (res.stderr || res.stdout).trim() };
  }
  // The probe's whole point: the comment came back. A binary that answers 0
  // and swallows it is one whose output must never be written to a file.
  if (!res.stdout.includes('rill vscode probe')) {
    return { ok: false, reason: 'mangled', detail: 'the probe program came back without its comment' };
  }
  return { ok: true };
}

/**
 * Format `source`.
 *
 * Returns {status, text?, detail?} where status is one of:
 *
 *   'formatted'   — text is the program to write. The ONLY status that edits.
 *   'unchanged'   — it was already formatted; no edit, and no message.
 *   'missing'     — no binary. No edit.
 *   'unsupported' — the binary does not understand the subcommand. No edit.
 *   'parse-error' — the file does not parse. No edit, and no message either:
 *                   the diagnostics already say so, in the right place.
 *   'refused'     — anything else went wrong. No edit, one message.
 *   'suspect'     — it came back shorter in comments than it went in. No edit,
 *                   and this one is LOUD: it is the failure that eats prose.
 */
async function formatSource(binary, args, source, opts = {}) {
  const res = await run(binary, args, source, opts);

  // Guard 1 — there is no binary, or it never ran.
  if (res.spawnError) {
    return { status: 'missing', detail: res.spawnError.message };
  }
  // Guard 2 — it ran and refused. 64 is "I do not know this command"; 65 is
  // "your file does not parse", which is not the formatter's news to break.
  if (res.code === EX_USAGE) {
    return { status: 'unsupported', detail: (res.stderr || res.stdout).trim() };
  }
  if (res.code === EX_DATAERR) {
    return { status: 'parse-error', detail: (res.stderr || res.stdout).trim() };
  }
  if (res.code !== 0) {
    return { status: 'refused', detail: (res.stderr || res.stdout).trim() || `exit ${res.code}` };
  }
  // Guard 3 — exit 0 and nothing came back. A non-empty file never formats to
  // nothing, so this is a broken binary, not an empty program.
  if (source.trim().length > 0 && res.stdout.trim().length === 0) {
    return { status: 'refused', detail: 'the binary exited 0 and returned nothing' };
  }
  // Guard 4 — prose. Comments are load-bearing here and a formatter that
  // drops one is not a formatter.
  const before = countCommentLines(source);
  const after = countCommentLines(res.stdout);
  if (after < before) {
    return {
      status: 'suspect',
      detail: `the formatted program has ${after} comment lines where the file has ${before}`,
    };
  }
  if (res.stdout === source) return { status: 'unchanged' };
  return { status: 'formatted', text: res.stdout };
}

/**
 * Parse a `check --json` reply.
 *
 * Tolerant on purpose, and only in ways that cannot invent a diagnostic: the
 * payload may be on stdout or stderr, it may be a bare array or an object
 * with a `diagnostics` key, and a line that is not JSON is ignored rather
 * than shown. What it will not do is guess a position — an entry without a
 * line number is dropped, because a squiggle in the wrong place is worse than
 * no squiggle.
 */
function parseDiagnostics(stdout, stderr) {
  const texts = [stdout, stderr];
  for (const text of texts) {
    const trimmed = (text || '').trim();
    if (!trimmed) continue;
    let payload = null;
    try {
      payload = JSON.parse(trimmed);
    } catch {
      // A binary that also logs will have one JSON line among the noise.
      for (const line of trimmed.split('\n')) {
        const t = line.trim();
        if (!t.startsWith('{') && !t.startsWith('[')) continue;
        try { payload = JSON.parse(t); break; } catch { /* not this line */ }
      }
    }
    if (!payload) continue;
    const list = Array.isArray(payload) ? payload
      : Array.isArray(payload.diagnostics) ? payload.diagnostics
        : null;
    if (!list) continue;
    const out = [];
    for (const d of list) {
      const line = Number(d.line);
      const col = Number(d.col ?? d.column);
      if (!Number.isFinite(line) || line < 1) continue;
      out.push({
        line,
        col: Number.isFinite(col) && col >= 1 ? col : 1,
        endLine: Number.isFinite(Number(d.end_line)) ? Number(d.end_line) : null,
        endCol: Number.isFinite(Number(d.end_col)) ? Number(d.end_col) : null,
        severity: typeof d.severity === 'string' ? d.severity : 'error',
        code: typeof d.code === 'string' ? d.code : '',
        message: typeof d.message === 'string' ? d.message : String(d.message ?? ''),
      });
    }
    return out;
  }
  return null;
}

/**
 * Check `source`.
 *
 * Returns {status, diagnostics?, detail?}:
 *
 *   'ok'          — it parses. Clear the squiggles.
 *   'diagnostics' — it does not. Show these.
 *   'missing' | 'unsupported' | 'unreadable' — no binary, no subcommand, or a
 *                   reply this client cannot read. Leave the squiggles alone
 *                   rather than clearing them on a guess, and say so once.
 */
async function checkSource(binary, args, source, opts = {}) {
  const res = await run(binary, args, source, opts);
  if (res.spawnError) return { status: 'missing', detail: res.spawnError.message };
  if (res.code === EX_USAGE) {
    return { status: 'unsupported', detail: (res.stderr || res.stdout).trim() };
  }
  const parsed = parseDiagnostics(res.stdout, res.stderr);
  if (parsed === null) {
    // Exit 0 with nothing to say is a clean parse from a binary that keeps
    // quiet. Anything else is a reply we cannot read, and guessing "fine"
    // would clear real squiggles.
    if (res.code === 0) return { status: 'ok', diagnostics: [] };
    return { status: 'unreadable', detail: (res.stderr || res.stdout).trim() || `exit ${res.code}` };
  }
  if (parsed.length === 0) return { status: 'ok', diagnostics: [] };
  return { status: 'diagnostics', diagnostics: parsed };
}

module.exports = {
  run,
  resolveBinary,
  countCommentLines,
  probeFormat,
  formatSource,
  checkSource,
  parseDiagnostics,
  PROBE,
  EX_USAGE,
  EX_DATAERR,
};
