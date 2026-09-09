# Changelog

## 1.0.1 — 2026-09-10

Fixes one parser bug. No syntax changes, no behaviour changes anywhere else.

### Fixed

A type-first declaration with **no initialiser and a trailing comment** was not
recognised as a declaration and was copied into the output verbatim, comment and
all — and `Node2D? target  # who we chase` is not GDScript, so the generated file
would not load.

```gdscript
vec2i[] tiles           # Array[Vector2i]      <- was emitted as-is
Node2D? target          # nullable, and tracked
priv float speed        # no initialiser
```

Comments are tokens, and the check that decides whether a line is a type-first
declaration required the token after the name to be a newline, `=`, `:` or `,`. A
trailing comment sits exactly where the newline would be. Declarations *with* an
initialiser were unaffected, because the check matched on `=` before it ever
reached the comment, and the `{K, V} name` form was unaffected because it returns
before looking that far.

Every form is pinned in the regression suite, including the two that already
worked, so a future fix cannot trade one for the other.

## 1.0.0 — 2026-09-09

First release. GATE is a GDScript superset that compiles to plain GDScript: valid
GDScript renamed to `.gate` must compile with zero errors, load, behave identically,
and be a byte-identical fixed point on recompile. Everything below is in service of
that promise.

Requires **Godot 4.7**. MIT licensed.

### What is in it

Types and nullability (`T?`, `?.`, `?[`, `??`) with a flow-sensitive null analysis
carrying interprocedural effect summaries; typed collections with Packed lowering;
`struct` with value semantics, lowered to a Vector where it fits and a class
otherwise; `interface`, `trait`, `namespace`; generics, monomorphised once in their
declaring file so `is Box<int>` holds across files; operator overloading; arity-based
overloads; `@observable`; `@soa`; f-strings, destructuring, `enumerate`; cross-file
declarations linked through injected `preload` consts; a sourcemap next to every
generated file; and an editor plugin that builds the project on save.

### Verification

A 20-stage suite, every stage able to fail (kept in development, not shipped here).
Beyond GATE's own tests it
is checked against **186 real Godot project roots** swept from their own directories —
the official demo, tutorial and benchmark repos plus ten shipped applications and games
— **1,093 files, 100,574 lines, zero compile errors, zero outputs that fail to load,
zero fixed-point breaks** — and, separately, every `.gd` in both corpora (**7,567 files**,
`addons/` included) compiled and recompiled from its own output with **zero fixed-point
breaks**. Two real projects, beehave and GodSVG, were also converted wholesale to GATE
and built through the plugin, with **zero files where only GATE's output fails to
load**.

The suite exists because six rounds of adversarial review each found defects while
every stage was green: roughly 60, 40, 26, 50, 65 and 8. The last two rounds are why the
final three stages exist at all — nothing recompiled a `.gate` source from its *own*
output (the superset stage skips anything carrying the generated banner), nothing
compared output byte for byte, and nothing noticed when the parser gave up on a member
and passed it through as raw text, which silently dropped a whole file out of every
analysis pass while leaving it loadable.

Two lessons are recorded at the top of `README.md` and neither is about an individual
bug: *a green stage is evidence the corpus does not contain the bug, not that the
compiler does not — and a test that pins the right input with the wrong assertion will
keep passing forever.* And: *harden a walker and you must harden its twin* — three of
the last round's defects were one walker fixed and its counterpart left alone, which no
test can see, because both are exercised by the same inputs and only one is wrong.

### Performance

Measured through `godot-benchmarks`' own harness on Godot 4.7.2, against a run-to-run
noise floor of 1.6% median:

* **GATE's output is performance-neutral against hand-written GDScript.** Across 110
  benchmarks the median ratio is 0.98; every difference outside the ported cases is
  inside the noise floor.
* **Escape analysis and scalar replacement** (new in this release):
  a struct local that provably never escapes becomes one plain local per field, with
  no allocation and no `_gate_copy()`. Measured **13.5×** against the class form GATE
  used to emit (27.5 ms vs 372.5 ms, 300k iterations, identical results).
* **Struct lowering** is 9.9× faster than the idiomatic `Array[SomeClass]` end to end.
* **`@soa` was re-measured twice, and both earlier claims were wrong** — first "1.9×
  faster", then "1.27× slower". Both measurements were real; both descriptions folded
  construction and iteration together, and those point in opposite directions. Timed
  apart: `@soa` is **~2.4× slower to build and 1.9× faster to iterate**, so it pays for
  itself after about 1.3 passes per rebuild. Build once and iterate every frame — a
  particle system, a simulation — and it is worth 1.9× per frame; rebuild every frame
  and walk it once and it is not. `godot-benchmarks`' `nbody` ported to `@soa Body[]`
  measured **1.93×**, which is the same number on a real workload. The README carries
  the table and the command that reproduces it.

### Not in this release

**Local type inference.** Emitting `var x := expr` for a bare `var x = expr` was built,
measured (1.24×–1.66× per converted local) and withdrawn. Typing a local changes how
GDScript checks every *use* of it, not just its assignments, and `0 < hp < 100` is one
member of an unbounded family that stops compiling once `hp` is concrete. Coverage on
real code was 2.2% of untyped locals, because 94% of untyped initialisers call engine
APIs whose return types GATE cannot see. Not worth the risk to the superset promise.
`README.md` carries the full reasoning.

### Known limitations

Comments are dropped, including `##` doc comments. `as` is trusted by the null
analysis and aliasing is invisible to it — both documented and deliberate. Expression
nesting is capped at 48 levels. The full list, with reasoning, is in `README.md`.

The honest gap: nobody has yet shipped a game written in GATE.
