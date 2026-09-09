#!/usr/bin/env node
// A stand-in for the rill binary, with one mode per way it can let us down.
//
// The client's guards are the only thing between a broken toolchain and a
// corrupted file, and a guard that has never met the failure it guards
// against is a comment. So each mode here is a real binary behaving badly,
// and each one has a gate in client.test.mjs standing over it.
//
//   usage:  node rill.mjs <mode> [the real arguments, ignored]

import { readFileSync } from 'node:fs';

const mode = process.argv[2];
let input = '';
try {
  input = readFileSync(0, 'utf8');
} catch {
  input = '';
}

const out = (s) => process.stdout.write(s);
const err = (s) => process.stderr.write(s);

switch (mode) {
  // A formatter that is a perfect no-op: whatever went in comes back.
  case 'echo':
    out(input);
    break;

  // A formatter that does something: two-space bodies become four, which is
  // the ruling of 2026-09-09 and the formatter's actual first job.
  case 'reindent':
    out(input.split('\n').map((l) => {
      const m = /^(  +)(\S.*)$/.exec(l);
      if (!m) return l;
      return ' '.repeat(m[1].length * 2) + m[2];
    }).join('\n'));
    break;

  // Exit 0 and hand back nothing. The failure that empties a file.
  case 'empty':
    break;

  // Exit 0 and hand back the program with its prose deleted. The failure that
  // eats four-fifths of roaches.rill.
  case 'strip-comments':
    out(input.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n'));
    break;

  // "I do not know this command line." sysexits EX_USAGE.
  case 'usage':
    err("unknown subcommand 'fmt'\nusage: rill <run|roundtrip|test|seam>\n");
    process.exit(64);
    break;

  // "Your file does not parse." sysexits EX_DATAERR.
  case 'dataerr':
    err('4:12: unknown operator or name \'fooo\'\n');
    process.exit(65);
    break;

  case 'check-ok':
    out('{"ok":true,"diagnostics":[]}\n');
    break;

  case 'check-bad':
    out(JSON.stringify({
      ok: false,
      diagnostics: [
        { line: 4, col: 12, severity: 'error', code: 'unknown_operator', message: "unknown operator or name 'fooo'" },
        { line: 9, col: 1, severity: 'error', code: 'parse', message: 'expected name after \'as\'' },
      ],
    }) + '\n');
    process.exit(65);
    break;

  // A reply nothing can read, with a failure exit. The client must not read
  // that as "all clear" and wipe real squiggles.
  case 'garbage':
    err('Segmentation fault\n');
    process.exit(139);
    break;

  default:
    err(`stub: unknown mode '${mode}'\n`);
    process.exit(64);
}
