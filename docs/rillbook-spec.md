# rillbook — the notebook console

**Status:** Mini-spec v0.1 · 2026-08-24 · replaces the terminal console page in the
web console. Companion: `rill-spec.md` (language), `rill-agents.md` (temporal/
failure/watchability), `rill-adoption.md` (routing, acks, Phase D).
**Model:** SQL Server, not bash. An editor over a batch boundary, not a prompt.
Compose in a real buffer, execute a selection or a cell, results land below,
the buffer persists. Jupyter's actual gift applies too: the artifact of
exploration is the artifact you ship.

**Motivating findings (Chris's first drive, 2026-08-24, transcript in ledger):**
multi-statement programs cannot be typed interactively at all (single-line input
vs newline-separated statements); console one-shots read values and discard them
(bare expression → mute `ok`); mid-chain `set` with a dot-form target may miss
the line-level fold (under investigation); `bad argument` names nothing.

---

## 1. Shape

Two inputs, one dispatcher, same correlated bus:

- **Quick bar** — the existing one-line input, kept verbatim. Quake-console
  muscle memory for `volume set v1 …`. No behaviour change.
- **Notebook** — a vertical list of **cells**, each a Monaco editor with rill
  syntax. This is the new surface and the rest of this spec.

## 2. Cells

A cell holds one rill program (one or more statements). Two run modes, chosen
per cell:

- **Run (query)** — dispatch as today's one-shot: mount → tick 0 → unmount.
  Reply renders in the cell's result pane. Ctrl/Cmd-Enter.
- **Mount (persistent)** — the cell's toggle. Mounting and re-running both send
  `rill remount <cellname> <source>` (landed 2026-08-24): the source text rides
  the line verbatim, newlines included, so a multi-statement cell is sayable in
  one command; a name that is not yet mounted simply mounts. The cell border
  lights while mounted. A re-run is **one adjacent pair in the log** — the
  unmount and the mount happen in one main-thread step at the same tick, with
  nothing logged between them, which is what makes the re-run recognisable as a
  single act. Unmount from the same toggle. The cell IS the mounted program's
  source of truth; `rill list` and lit cells must agree (assert in tests, not by
  convention).

  **Phase-E dependent (do not build expecting it):** *undo* of a re-run
  restoring the prior program. rill mount/unmount events are not undoable at
  all today — the transcript's two views are Phase E work. Adjacency in the log
  is what phase 2 delivers; undoing the pair as a unit waits for the phase that
  makes rill events undoable.

Cell names: auto (`cell-1`, …) until the user names them; the name is the mount
name, namespaced per the agents-doc ruling (`user/<name>` from the browser).

**Bare-expression echo (semantic fix riding along):** a one-shot whose final
statement is an expression (no sink) replies with that value, rendered by
struple type. This dissolves the mute-console finding rather than patching it —
"what does this print" now has a pane to print into. Engine-side: the one-shot
runner returns the last node's out-slot when no reply was set.

## 3. Result panes

Under each cell, fed by the machinery that already exists:

- Query replies: the correlated ack (the client already groups by id).
- Mounted cells: a live strip — `tap` output and `programs.<name>.errors`
  occurrences as they land on the log bus (Phase D's tap→bus wiring), plus the
  per-node eval/error counters from `programs[]` when the main-rendered schema
  ships. Until Phase D lands, mounted cells show mount/unmount acks only; the
  pane grows richer as D items land, with no rework.
- Errors: the rill diagnostic verbatim, with the cell's line/column highlighted
  in Monaco (the parser already reports positions; if any diagnostic lacks one,
  that's a rill-core fix, not a UI workaround).

## 4. Editor intelligence (all served, nothing invented)

- Syntax highlighting from a static rill grammar (operators/keywords) —
  registry-driven token classes are a later nicety, not v1.
- Completions: operator names + port signatures from `schemaJson.commands[]`;
  knob paths from the schema's knob table; `plane.` path completion reuses the
  quick bar's existing tab-complete data. One source, never two that drift —
  the notebook consumes the same JSON the quick bar does.
- Hover: an operator's `help` text and port list (same data as `usage`).

## 5. The document

A notebook is a `.rillbook` file: an ordered list of cells
`{name, source, mode: query|mounted, collapsed, markdown?}` — markdown cells
allowed for commentary, making it the literate authoring format. Stored like
rigs (save/load from the console's file row), versioned with a format integer
per the house rule. Saving a notebook does NOT save mount state side effects;
loading one offers "mount all previously-mounted cells" as one explicit action
(logged as its individual mounts — replay stays honest).

Deliberately deferred: notebooks in the Project pack (they belong there
eventually, next to rigs — take it when a game ships one), cell reordering
semantics beyond drag (order is presentation; mounts are independent), and any
kernel-style execution state between cells (cells share nothing except the
plane, which is the point — no hidden notebook-local bindings).

## 6. Non-goals

- Not a REPL with implicit session state. Cells are independent programs; the
  plane is the only shared state. `as` names do not leak between cells.
- Not a replacement for `.rill` files in rigs — a notebook can be *exported*
  to plain `.rill` (concatenate mounted cells) but rigs keep carrying programs
  exactly as Phase B built.
- No execution of cells on load, ever, except via the explicit mount-all
  confirmation.

## 7. Gates

- N1: a two-statement program (the `window 2s | stats` demo) is composed,
  mounted, edited, re-mounted from one cell; `rill list` agrees with lit cells
  at every step, and each re-run leaves exactly one adjacent unmount+mount pair
  at one tick in the log (the engine-side half of this is gated already).
- N2: bare-expression cell echoes its value; the same line via the quick bar
  echoes identically (one dispatcher, proven).
- N3: a parse error highlights the offending line/column in the cell; the
  diagnostic text matches the quick bar's for the same line.
- N4: save → reload → mount-all reproduces the mounted set; the log records
  individual mounts; replay of that session is bit-identical.
- N5: mounted cell's error strip shows a deliberate `div` by zero as an error
  occurrence with node/tick named (lands with Phase D; gate written now).
- N6: the quick bar's behaviour is byte-identical before/after the notebook
  ships (it is untouched machinery, proven untouched).

## 8. Build notes

Monaco is a drop-in; the ack bus, schemaJson completions, and mount verbs all
exist. This is arrangement, not machinery: est. one page of new client code
plus the bare-expression echo engine-side. Sequence after the current
migration phase lands (the class column / inbox work), so the notebook is born
onto the honest routing rather than the interim one. The three findings that
motivated this (multi-line input, mute expressions, the mid-chain set fold)
should be fixed/triaged in rill core and serve.zig independently of the UI —
the notebook must not be the workaround for a parser or fold bug.
