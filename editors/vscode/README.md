# rill for VSCode

Syntax, outline, snippets, formatting and diagnostics for `.rill`.

Highlighting, the outline, the snippets and the indent rules work with nothing
installed but this folder. Formatting and diagnostics need a `rill` binary that
speaks the contract in [The CLI contract](#the-cli-contract) — **rill has
shipped one since 2026-09-09**; see [Get the binary](#get-the-binary). If it is
not on `PATH` they turn themselves off with one message, and nothing else
changes.

---

## Install

One block, about forty seconds:

```sh
mkdir -p ~/.vscode/extensions
ln -s ~/dev/rill/editors/vscode ~/.vscode/extensions/foundation42.rill-0.1.0
```

Then in VSCode: `Ctrl+Shift+P` → **Developer: Reload Window**. Open any `.rill`
file.

A symlink rather than a `.vsix` on purpose — it is the honest one. The
extension is plain JavaScript with no build step and no runtime dependencies,
so what runs in the editor is the file in the repo: edit `syntaxes/…`, reload
the window, see the change. A packaged `.vsix` would be a copy that silently
stops tracking the tree.

To uninstall: `rm ~/.vscode/extensions/foundation42.rill-0.1.0`.

### Get the binary

Formatting and diagnostics shell out to `rill`, which `zig build` produces in
the rill checkout. `rill.binaryPath` defaults to the bare name, so it has to be
on `PATH`:

```sh
cd ~/dev/rill && zig build && ln -sf "$PWD/zig-out/bin/rill" ~/.local/bin/rill
```

A symlink for the same reason the extension itself is one: `zig build` then
updates what the editor runs, with nothing to reinstall. Check it with
`rill version`, or from inside VSCode with **rill: Check the rill binary**.

**In a spindrift or matryoshka workspace, name your host's words.** rill core
does not know `spawn` or `near` and must not — the registry is the host's — so
without `--host-row` a fifth of the files in this checkout do not format and
report false unknown operators. Both settings, in `.vscode/settings.json`:

```jsonc
{
  "rill.format.args": ["fmt", "--host-row", "-"],
  "rill.diagnostics.args": ["check", "--json", "--host-row", "-"]
}
```

If you would rather have a package to hand to someone else:

```sh
cd ~/dev/rill/editors/vscode
npx --yes @vscode/vsce package --no-dependencies   # writes rill-0.1.0.vsix
code --install-extension rill-0.1.0.vsix
```

That produces ten files and 31 KB: `.vscodeignore` keeps `node_modules/`, the
tests and the fixtures out. The dev dependencies back the gates only — the
extension itself requires nothing but the `vscode` module the editor supplies,
which is why a bare symlink into `~/.vscode/extensions` works with no
`npm install` at all.

---

## What you get

**Highlighting** that follows rill's own tokenizer rather than a guess at it —
`//` is a comment and `#` is not, `:k.tight` is a fold reference and a
projection, `$wind` keeps its sigil, `plane`/`row`/`slate` read as the three
stores, `@self` reads differently from `@roaches`, and a duration is one
literal. Chosen against the real Dark+ and Light+ so it looks right with no
theme of your own; `npm run preview -- test/fixtures/showcase.rill` paints a
file in the terminal with those exact colours if you want to check.

**An outline** in the breadcrumb and the Outline view, built from the text
alone so it works before anything is compiled. Its spine is your own prose:

```
THE STORES                      ← // ══ TITLE ══
  the room                      ← // ── title ──
    :k          plane.drift.@self.k
  literals
THE PACK
  roaches       Cockroaches milling on a floor, scattering and regrouping.
    rate        = 60 (0..500)
    speed       = 0.15 (0..5)
```

`roaches.rill` is four-fifths comment, and an outline that showed one `def` for
it would be describing the wrong document. Banners chapter the file, `def`
ports hang off their definition, an exported def wears the first line of its
`describe` block as its summary, folds and `as` names appear where they were
bound — and because names are single-assignment and must be defined before
use, the outline's order **is** the schedule's order.

**Snippets** for the shapes you actually type — `exportdef` brings its
`describe` block (an exported def must describe itself, so a snippet that
omitted it would be teaching a refusal), `kernel` brings a whole spray package,
`using`, `def`, `defrow`, `describe`, `also`, `section`.

**Four spaces**, ruled 2026-09-09, set as the language default so the editor
and `script.zig`'s printer agree. `//` continues onto the next line on Enter,
and so does a leading `|`.

**The wrapped forms**, because the printer breaks a line that runs past **88
columns** and the editor has to agree with it. A signature that wraps opens
with a bare `(` and closes on a `) =` that dedents itself and indents the body
under it; an array that wraps opens with `[` and closes on a `]`, laid out by
its count — a few stacked one per line, many packed, sixteen as 4×4; a chain
that wraps puts one stage per line with the `|` in the left margin of the
continuation, and Enter after one of those keeps the column the printer chose
rather than stepping right. The first `|` of a chain is still yours to indent
— no lexical rule can tell a statement that is about to be continued from one
that is finished, and indenting after every statement in the file on the
chance that a pipe follows would be worse than one Tab.

Snippets follow the same canon in both directions: `kernel`'s six-port
signature is written broken because it is 149 columns flat, and `exportdef`,
`def` and `defrow` are written flat because they fit. A snippet wrapped for the
look of it would be flattened by the first save, which is the same failure as
one that runs long.

**Formatting and diagnostics**, when a binary can back them. See below.

---

## The CLI contract

This is what the extension needs from `rill`, and **as of 2026-09-09 `rill`
provides it** — `src/cli.zig`, gated by `F1`..`F19` in the same file. It is
still written as a spec rather than as documentation of an implementation,
because it is the contract that binds: an editor and a compiler are two
programs, and the thing between them is the interface, not either one's code.

All three subcommands are a front door onto machinery that already existed:
`fmt` is `parse` + `script.print` (the printer landed the same day), `check` is
`parse` and the `Diag` it fills, `ops` is the registry read out.

**The extension uses two of the three.** `ops` is documented here because this
is where the CLI's contract lives, not because the client calls it — see
"`rill ops`", below, for why it does not.

### `rill fmt -`

```
stdin   the program, whole
stdout  the formatted program, and nothing else
stderr  anything it needs to say
```

| exit | meaning |
| --- | --- |
| `0` | formatted; stdout is the program |
| `64` | the command line was not understood — unknown subcommand, unknown flag |
| `65` | the input did not parse; stdout is **empty** |
| `70` | an internal failure |

Four requirements, and the first is the one the extension refuses to work
without:

1. **Comments come back.** `roaches.rill` is roughly four-fifths `//` lines and
   they are the only documentation of the numbers in it. The extension proves
   this before it will format anything: it sends `// rill vscode probe\n` once
   per session and formats nothing unless that comment is in the reply.
2. **Idempotent.** `fmt(fmt(x)) == fmt(x)`. Format-on-save runs on every save.
3. **Empty in, empty out, exit 0.** A program with no statements is a program.
4. **Nothing but the program on stdout.** A log line on stdout is written into
   the file.

Gated as `F1`..`F5` in `src/cli.zig`, and `X1` here: `rill fmt` over all 47
`.rill` programs in this checkout returns every one of them byte-identical.

`64` and `65` have to be told apart. `64` means the feature is not there and
the extension says so once and goes quiet; `65` means the file does not parse,
which is not the formatter's news to break — the squiggle already said it, in
the place it happened.

### `rill check --json -`

```
stdin   the program, whole
stdout  exactly one JSON object
```

```json
{
  "ok": false,
  "diagnostics": [
    {
      "line": 12,
      "col": 5,
      "end_line": 12,
      "end_col": 14,
      "severity": "error",
      "code": "unknown_operator",
      "message": "unknown operator or name 'fooo'"
    }
  ]
}
```

| field | required | notes |
| --- | --- | --- |
| `line` | yes | 1-based, as `Diag.line` already is |
| `col` | yes | 1-based, as `Diag.col` already is |
| `end_line`, `end_col` | no | omitted, the client underlines the token at the caret |
| `severity` | yes | `"error"` or `"warning"` |
| `code` | **yes** | stable, snake_case — see below |
| `message` | yes | `Diag.msg()`, verbatim |

| exit | meaning |
| --- | --- |
| `0` | `"ok": true`, `diagnostics` empty |
| `64` | the command line was not understood |
| `65` | it did not parse; `"ok": false` and at least one diagnostic |
| `70` | an internal failure — the client leaves existing squiggles alone rather than clearing them on a guess |

The parser stops at the first refusal, so `diagnostics` holds exactly one entry
today. It is an array because that shape survives a parser that later reports
more, and a client written against a bare object would not.

**`end_line`/`end_col` are not sent**, and that is a choice rather than a gap:
`Diag` carries no end, and the client derives a better one than a token length
would be — it widens the caret over the whole dotted run, so a refusal on
`plane.drift.@self` underlines all twenty characters instead of the five that
are `plane`. Sending a token-shaped end would make the squiggle worse. See
`spanFor`, gate `E7`.

**`prog.warnings` is dropped.** The parser has one non-fatal diagnostic today
("block discards a value") and `check` does not report it, because a warning
carries no `code` and a client that cannot name what it is looking at cannot
decide what to do with it — which is the exact argument that put `code` on
`Diag`. Recorded, not built. The trigger is a second `warn` site in the parser,
or a request for that one in the editor; building it means a `code` on
`graph.Warning` first.

#### `code` is required, and here is why

**The operator registry is open.** The host injects its words at startup, so a
`check` built from rill core alone does not know `spawn`, `near`, `push` or
`drift` — those are spindrift's and matryoshka's — and it will report
`unknown operator or name 'spawn'` on 21 of the 47 corpus programs. Every one
of those is a lie.

That is a measurement, not an estimate. `rill check --json -` over the corpus:
**26 clean, 21 `unknown_operator`, 0 anything else.** With `--host-row`:
**47 clean.** So spindrift's fifteen cover the whole of it today — matryoshka's
own words are all two-word verbs its `.rill` files do not reach for.

With a `code`, the client can tell that diagnostic from a real syntax error and
downgrade it (`rill.diagnostics.unknownNames`, a warning by default). Without
one, the only honest default is to turn diagnostics off, which is a feature
nobody gets.

The minimum set the client cares about:

| code | for |
| --- | --- |
| `unknown_operator` | `unknown operator or name '<x>'` — the one that must be distinguishable |
| `parse` | everything else the parser refuses |

Anything finer is welcome (`reserved_name`, `already_defined`,
`undescribed_port`, `unknown_described_port`, `def_reach`, `row_word_on_world`)
and the client passes unknown codes straight through as errors.

**Two is what rill sends**, deliberately. `Diag.Code` has exactly those two
values because there are 184 refusal sites in `parser.zig` and one consumer
asking one question; `parse` is the DEFAULT, so a site nobody has asked about
answers honestly rather than claiming a kind it was never taught. A finer
taxonomy is a beat of its own, and it is additive: this client already passes
a code it does not recognise straight through.

### `rill ops [--host-row] [--tag <name>]... [--name <substring>] [--json]`

Landed 2026-09-09 with `OpDef.tags`. It prints the operator vocabulary — each
word with its `help`, filed under its **home tag**, with a short noun and a
sentence per tag.

```
stdin   NOT READ — the input is the registry this binary was built with
stdout  the listing, or one JSON object with --json
```

| exit | meaning |
| --- | --- |
| `0` | the listing is on stdout — **or the filter matched nothing**, which is said on stderr |
| `64` | the command line was not understood — including an unknown `--tag`, refused BY NAME with the list |
| `70` | an internal failure |

`65` is unreachable: `ops` parses no program, so there is no program for it to
refuse. **It reads no stdin at all**, which is a contract and not an
implementation note — a build that read it would sit at a terminal waiting for
a program nobody is going to type. Gated as `X6` here, because this suite is
the only one in the repo that runs the binary as a process.

**A typo and an empty result are different answers**, and under a filter model
that matters more than under a tree: `--tag maths` is `64` naming the typo and
listing the tags that exist, while `--tag math --tag space` — two real tags
nothing carries together — is `0` with an empty stdout and `rill: nothing
matches …` on stderr. An empty page alone cannot tell those apart.

Ordering is part of the contract, so the output can be diffed and gated
byte-exactly: **headings sorted, operators sorted under them**, and the name
column padded to the widest name IN THAT HEADING — so `--tag record` prints the
same bytes whether or not a host registered something long.

```
record (3) — named fields: build one, read one, merge two
  merge    Merge two records; b's fields win.
  project  Field access on a record stream (`stats.mana`).
  record   Record construction { field: stream, … } — a live tuple with named fields.
```

An operator carries several tags and is found under every one; the FIRST is
its home, which is where a listing files it, and the rest print as an `also:`
line under the word. `--tag` is repeatable and **ANDs**.

A tag is what an operator is FOR. It is emphatically *not* `class` (purity),
`routes` (thread) or `row` (evaluator): those are checked by the parser and
the mount and refuse programs, a tag is descriptive and refuses nothing, and
folding one into the other would degrade a real refusal into a label. They
ride side by side in `--json`, so a client wanting "row-legal AND tagged
`space`" asks both columns.

Tags are declared at registration; a two-word name is at home under its FIRST
WORD, so `rbf bump` lands in `rbf` and a host's `(verb, subop)` console
vocabulary organises itself with no change over there; a one-word name with
nothing declared lands in `untagged`, and `rill ops --tag untagged --host-row`
is how you see who has not said yet.

`--json` carries what a palette needs to build a filter bar and draw a box: a
whole `tags` dictionary with each tag's sentence (**not** filtered with the
listing, or a palette would only ever learn about tags it had already asked
for), and per operator its `home`, `tags`, `class`, `routes`, `ticks`, `row`,
`inputs`, `outputs` and `statics` with names and types.

**The extension does not call it, and that is deliberate.** There is no
palette to feed. Completion here is a static snippet file and a symbol
provider over the open document; wiring a subprocess call into either would be
a feature with no customer, and the reason to build it is the graph editor,
not this. Trigger: a completion provider that wants live host words, or the
canvas.

### Host vocabulary

`--host-row` registers spindrift's fifteen row words as stubs, which is what
lets rill's own tools read a kernel without rill depending on spindrift. All
three subcommands take it, and the stubs have ONE definition — `tools/host_row.zig`,
shared with `tools/roundtrip.zig` — because a stub whose arity differs parses
the same file differently, and two copies that drift make the two tools
disagree about what a legal program is while both stay green.

Set BOTH args in a host workspace. `fmt` has to parse a file before it can
print it, so without the flag a spray kernel does not format at all — and
unlike a diagnostic, which arrives downgraded to a warning with its sentence
attached, that failure is silent by design ("the squiggle already said it").
The extension says one status line about it (`E8`); the setting is the fix:

```jsonc
// .vscode/settings.json in spindrift or matryoshka
{
  "rill.format.args": ["fmt", "--host-row", "-"],
  "rill.diagnostics.args": ["check", "--json", "--host-row", "-"]
}
```

### Not required, and still not built

Each recorded with the trigger that would build it, because recorded-not-built
without one is a wish.

- `--stdin-name <path>`, so a message can say which file it means. Trigger: a
  diagnostic that has to name a file, which needs more than one file first.
- More than one diagnostic per run. Trigger: the parser learning to recover;
  it stops at the first refusal today and the array shape is already right.
- `rill fmt --check -` (exit non-zero if reformatting would change anything),
  for CI. Trigger: a CI job. The extension does not use it, and the 47-file
  no-op claim it would serve is gated here as `X1` without it.
- Human-readable `check` output. `check` without `--json` exits 64 naming the
  flag, because a second reply shape invented with no reader is a second thing
  to keep in step. Trigger: someone reading `check` at a shell.

### What the extension does when the binary is missing or older

Nothing bad, and it says so once.

- No binary → one status-bar line naming `rill.binaryPath`; formatting and
  diagnostics are off, everything else works.
- Exit `64` → one line saying the binary does not understand the subcommand.
- The probe comes back without its comment → a **warning popup**, and
  formatting stays off. That one is loud on purpose.
- Exit 0 with an empty stdout, or a reply with fewer `//` lines than went in →
  the format is refused and the document is untouched. The second is an error
  popup.
- Exit `65` → the document is untouched and no popup: the squiggle already
  said it. One status line names `--host-row`, because a spray kernel checked
  without the host's words is the commonest reason Format does nothing.

`rill: Check the rill binary` in the command palette runs both calls and prints
what came back.

---

## Settings

| setting | default | |
| --- | --- | --- |
| `rill.binaryPath` | `rill` | bare name → `PATH`; a relative path → resolved against the workspace |
| `rill.format.enable` | `true` | |
| `rill.format.args` | `["fmt", "-"]` | add `--host-row` in a spindrift or matryoshka workspace, or kernels do not format |
| `rill.diagnostics.enable` | `true` | |
| `rill.diagnostics.args` | `["check", "--json", "-"]` | add `--host-row` in a spindrift or matryoshka workspace |
| `rill.diagnostics.run` | `onType` | or `onSave`, or `off` |
| `rill.diagnostics.unknownNames` | `warning` | how to report `unknown_operator` — `error` once the args name your host's words |

---

## What the grammar deliberately does not do

Three things, all for the same reason: **the operator registry is open**, so no
static list in a highlighter can be right.

1. **It does not know the operator set.** A word in head position — the start of
   a statement, or straight after a `|` — is scoped as an operator, whether it
   is `perish`, matryoshka's `drift`, or a local `as` name being piped
   (`t | write plane.follow.t`). Colouring the third as a verb is the price of
   never being wrong about the first two, and a chain reads as a chain either
   way. In argument position the same name is a variable, which is how every
   TextMate grammar behaves at a call site.

2. **It does not know which operators are two words.** Lookup tries the
   two-word form first, so `rbf through` is one operator — and `rbf` is rill
   core's only two-word family, so it is the only one spelled out. A host's
   (`drift spawn`, `light move`, `sprayarche kernel` — 170 of them in
   matryoshka today) gets its verb scoped and its sub-op left as an argument,
   because `drift spawn` and `along track` are the same two tokens and only the
   registry knows which is which. A generic rule was tried and measured: it
   turns every curve-drawing kernel in matryoshka yellow. `G5b` is that
   measurement, kept.

3. **It does not know which ports are tails.** A `tail` port binds the rest of
   the line verbatim from raw source (§3.11) and only the registry knows a port
   is one, so a locator is highlighted as ordinary argument tokens rather than
   as text. The concession made is one the tokenizer cannot contradict: a `/`
   that does not join two name characters has no meaning in rill at all, so a
   `/`-led run is a locator and comes out whole — `/tmp/loop.wav` stays one
   piece. `pack:horns#audio.stem` stays structured, and every piece of it keeps
   a sensible scope; its `:` is not read as a fold, because a fold colon glues
   right and that one glues left.

   **The blind spot that remains is `//` inside a tail.** `sound play
   https://example.com/x` highlights from the `//` as a comment. rill's own
   tokenizer does exactly this outside a tail — `//` at a token boundary is
   always a comment — so the grammar is faithful; what it cannot see is the
   tail's exemption from that rule. Fixing it would mean disagreeing with the
   tokenizer to be helpful, which is how a highlighter becomes a second,
   quieter parser that drifts from the first one.

Also not attempted, and each for a reason worth stating:

- **No semantic highlighting.** Distinguishing a local `as` name from an
  operator at statement head needs the binding table, which means a whole
  second parser in JavaScript or a language server. Neither is worth the drift.
- **No hover or completion.** `help` text lives in the registry, which is the
  host's, and rill has no way to enumerate it over stdio yet. When it does,
  that is the next beat.
- **No `describe`-aware validation.** The parity check between an exported def
  and its `describe` block runs both ways in the parser and belongs there.

---

## The gates

```sh
npm install     # two dev packages: vscode-textmate, vscode-oniguruma
npm test        # 57 gates
npm run mutate  # 49 mutations, each must break the gate that names it
npm run preview -- ../../../matryoshka/kernels/roaches.rill dark
```

| file | what it stands over |
| --- | --- |
| `test/grammar.test.mjs` | the grammar — the corpus sweep and the named traps (`G*`) |
| `test/client.test.mjs` | `rillcli.js` and `symbols.js` — the decisions (`C*`) |
| `test/config.test.mjs` | `language-configuration.json` and the manifest (`L*`) |
| `test/extension.test.mjs` | the providers, over a stub `vscode` — the layer that touches a document (`E*`) |
| `test/e2e.test.mjs` | the REAL `rill` binary, and the seam between it and the client (`X*`) |

`test/e2e.test.mjs` is the half that was missing until the binary existed.
Every other suite runs against `test/stubs/rill.mjs`, a stand-in written to
behave badly in one named way per gate — the right shape for the client's
guards, since you cannot ask a real binary to eat your comments on demand, but
it means the stub answers whatever it was told to and never looks at its
arguments. So a wrong default in `package.json` shipped green. `X4` is that
gate now; `X1` is the one to read, and it is the strongest sentence in this
document: **`rill fmt` over all 47 `.rill` programs returns every one of them
byte-identical.**

The binary is found at `../../zig-out/bin/rill` or at `RILL_BINARY`. If it is
not there the `X*` gates SKIP — loudly, by name, with the command that builds
it, on stderr as well as in the report. A silent skip is a gate that watches
nothing.

`test/extension.test.mjs` exists because `client.test.mjs` stops at a status,
and the way to empty a file is to be right about the status and wrong about the
edit. `E3` is the one that matters: with no binary, the formatting provider
must return an empty edit list — which is the state of every machine on the day
this is installed.

`npm test` needs `spindrift` and `matryoshka` beside `rill`: the corpus gate
runs the grammar over all 47 `.rill` programs and asserts every non-whitespace
character lands in a real scope and none lands in `invalid.*`. rill is the
library the siblings embed and must not depend on either, which is why
`tools/roundtrip.zig` takes its corpus as arguments — same arrangement here.

`npm run mutate` is the half that makes the rest mean something. Each gate
names the mutation that must break it; `test/mutate.mjs` applies every one of
them to a copy of the tree and fails if any gate stays green. A mutation that
survives is reported as `SURVIVED`, which means the gate is watching nothing.

The `X*` gates stand over the BINARY, so most of their mutations live in
`rill/src/cli.zig` as the `F` series and were run there. What is mutable here
is the manifest — `X4` and `E6b` mutate a shipped default — and those bite only
because `test/fake-vscode.cjs` now DERIVES its defaults from `package.json`
instead of keeping a second copy. It kept a copy until 2026-09-09, which meant
every gate that read a setting read a value this repo made up.

The tokenizer under the gates is `vscode-textmate` + `vscode-oniguruma` — the
exact two packages VSCode loads to highlight a buffer — so what runs is the
real matcher against the real regex engine. The twenty lines that flatten its
answer to one scope list per character are ours; `vscode-tmgrammar-test` was
the other candidate and was rejected because its assertions are per annotated
column, and the gate that matters here is per character of 47 whole files.
