# raku-eye

The standing watch on fresh Raku code: every Monday, unattended, this repo
measures [rakupp](https://github.com/ash/rakupp) against what the ecosystem
just published, and publishes the result at **https://eye.raku.online**.

Four measurement legs, one run:

1. **Weekly Challenge** — new [challenge-club](https://github.com/manwar/perlweeklychallenge-club)
   solutions since the last run, the open mismatch set re-run, and a rotating
   10% of past passes. Differential against Rakudo, byte-for-byte.
2. **Ecosystem releases** — the week's new [REA](https://github.com/Raku/REA)
   distributions under `rakupp test`, with a Rakudo control for whatever
   fails (a dist Rakudo also rejects is upstream-broken and out of scope).
3. **[raku-corpus](https://github.com/ash/raku-corpus)** — ~1,800 curated
   programs against committed Rakudo reference outputs. One run per file;
   the flattest, purest regression tripwire in the set.
4. **Benchmarks** — rakupp (interpreter and `--exe` native) vs the latest
   Rakudo release, measured back-to-back on the same runner; the published
   series is the ratio, with markers wherever Rakudo or the toolchain moved.

No AI anywhere in the pipeline. It measures, clusters mismatches by
normalized error signature, and reports; fixing happens in rakupp, by hand.
The reported number is the number that came out — no retries, no dropped
weeks.

## Layout

    .github/workflows/weekly.yml   the Monday run
    tools/eye-run.raku             the driver: fetch / measure / eco / ledger
    tools/eye-report.raku          data/ in, static site out (inline SVG, no JS)
    state/                         what next week starts from
    data/                          append-only ledgers + per-week detail
    work/                          scratch, per run (not committed)
    site-build/                    the generated site (deployed, not committed)

The design, method, and rules live in
[RAKU-EYE-PLAN.md](https://github.com/ash/rakupp/blob/main/docs/dev/plans/RAKU-EYE-PLAN.md).
The tools are Raku and run under the rakupp binary built minutes earlier in
the same workflow — a week where rakupp cannot run its own measurement is a
red Monday, which is that week's most important finding.

`data/latest.json` is a stable, CORS-open summary for embedding —
raku.online's front page reads it.
