# Lazy phrase gate for ranked phrase queries (2026-10-01, ROADMAP I5)

## Where the time goes today (1.9.0, positions=on, `"united states"` k10, perf)

`bm25_topk_candidates_range` takes the non-pure-boolean path for a phrase:
`bm25_collect_matches` builds the exact phrase match set (361,465 TIDs) through
`bm25_phrase_eval_seg`, which decodes EVERY posting of BOTH terms with positions
(`bm25_decode_term(want_positions=true)`) and walks the full intersection checking
adjacency. Then WAND ranks the bag of words (`united | states`) with a `DocidFilter`
binary-searching that set. Collect + decode ~60%, WAND ~28%. All of the collect work
happens before the first candidate is scored, and for a top-10 almost none of it is
needed.

## The change

For a ranked query that is a pure phrase chain over a positions=on index (exactly the
cases `bm25_collect_matches` would take its positional fast path for), skip the up-front
collect. Instead, gate each WAND pivot lazily:

- WAND already ranks the term disjunction. A doc can be in the phrase set only if ALL
  phrase terms are present at the pivot (an AND precondition) -- check that first, for
  free, from the cursors.
- For a doc that passes, verify adjacency by decoding positions for just that doc,
  just those terms.

Getting a doc's positions without decoding the whole term: each WAND cursor holds the
current 128-posting block (a copy of its FOR payload). The block has a trailing
positions column (`posbytelen` bytes, `Sum(tf)` deltas). Copy that column too and decode
the block's positions once per block (not per doc), lazily -- only for a block whose doc
reaches the gate. Prefix sums over the block's tf column give each posting's slice.
Adjacency then uses the existing `fts_phrase_step_pos` on those slices.

Exactness:

- The gate admits a doc iff (every phrase term present) and (positions satisfy the same
  step distances `bm25_phrase_eval_seg` checks). That is the same predicate the collect
  path computes, so the admitted set is identical and the top-k is identical.
- Score arithmetic and traversal are unchanged (the gate only decides heap admission,
  like the existing `BoolGate`), so ranking is unchanged.

Falls back to the existing collect path when:

- positions are off for the index;
- the query is not a pure phrase chain (mixed with boolean ops, prefix/fuzzy/regex,
  NOT, weighted terms);
- a block's positions column is absent (`posbytelen == 0` -- the documented page-overflow
  case where `bm25_lookup_term_pos` returns NOPOS). The gate then answers "unknown", and
  the WHOLE query restarts on the collect path rather than guessing.

Also unchanged: count(*) / `@@@` bitmap scans (they still use the exact collect).

## Gate

`sql/phrase_gate.sql`: the lazy-gated top-k must equal the collect-path top-k (forced via
a test GUC) for many phrases, k values, with ties, NEAR/step distances, and after deletes.
A mutant that skips the adjacency check must fail it.
