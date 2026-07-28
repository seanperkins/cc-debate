# Evaluation harness

Tools for answering "did a prompt change actually make reviews better?" rather
than guessing. Built to evaluate the reviewer-calibration branch, but nothing here
is specific to it.

    check-citations.py   do the file:line citations resolve?   (no judgment needed)
    seed-defects.py      inject known defects -> ground truth
    score-run.py         score reviews against the manifest

## The problem these solve

You cannot measure a reviewer without knowing which findings are real, and nobody
knows that for a real plan. Two ways out, both used here:

1. **Mechanically checkable properties.** A citation either resolves or it does
   not. No model, no rubric, no opinion.
2. **Seeded defects.** Put the bug in yourself and you know what is there, what
   severity it deserves, and which persona should have caught it.

## Baselines measured on the pre-change corpus

Run against 20 reviews from four rounds of one spec (graphiti-kb mail ingestion,
2026-07-28), all produced by the **pre-calibration** prompts.

### Citations: already perfect — this metric has no headroom

```
683 citations across 20 reviews | 550 gradable | resolved 100.0%
hard failures: 0 bad-line, 0 missing
excluded: 35 proposed-not-yet-created, 98 plan self-refs
```

Citation hallucination is **not** a live problem in this system. The pre-change
Claude footer already carried "every file:line you cite must come from a tool
result in this session," and it worked across every review in the corpus.

Consequences, stated plainly:

- **This metric cannot discriminate between prompt versions.** You cannot beat
  100%. Anyone reporting a citation-accuracy win here is reading noise.
- It remains valuable as a **regression guard**: if a change drops this below
  100%, the change broke grounding.
- The grounding directive added to the acpx side is therefore justified on
  capability grounds (antigravity previously could not read the repo at all), not
  on a hallucination rate that was already zero.

Note the tool had to learn this the hard way: `plan.md:NNN` is a citation *into
the plan under review*, and the plan lives in a work dir that gets cleaned up.
Scoring those against the repo root reported 98 false "missing" and put the
headline 15 points too low. If you extend the matcher, re-check the buckets by
hand before quoting a number.

### Verdicts: 20/20 REVISE, 0 APPROVED

```
r1:       0 APPROVED / 5 REVISE
v1-rerun: 0 APPROVED / 5 REVISE
v2:       0 APPROVED / 5 REVISE
v3:       0 APPROVED / 5 REVISE
```

Three revisions, and after each one every reviewer still said REVISE. No reviewer
in the corpus has ever approved anything.

**This is suggestive, not conclusive.** It is equally consistent with:

- (a) reviewers cannot approve — no severity threshold, no stated permission to
  find nothing, so any nit forces REVISE; or
- (b) the plan genuinely still had blocking defects at v3.

The corpus cannot separate these, because the plan really was evolving. **The
control arm is what disambiguates**, which is why it is not optional below: on a
plan with nothing wrong, (a) predicts REVISE and (b) predicts APPROVED.

## Protocol

### Arms

Old prompts vs. new prompts, **paired** on the same plans, run **cold** (both arms
see the same plan version fresh). Do not compare new-arm reviews against the
existing corpus: those reviewers had already seen v1 and v2, which is a different
epistemic position and confounds the comparison.

### Plans

    python3 seed-defects.py --plan <plan.md> --out-dir variants/

Writes `seeded-plan.md` (7 defects: 2 CRITICAL, 4 MAJOR, 1 MINOR),
`control-plan.md` (untouched), and `manifest.json`.

**Run both.** Seeded recall alone cannot show precision improved — a reviewer that
flags everything scores perfect recall.

For the control to mean anything it must be a plan that is genuinely fine. The
best source is a change you already shipped that works, described accurately: it
is correct by construction.

### Reps

3 per plan per arm, minimum. These are high-variance samples.

Minimum useful experiment: 1 control + 1 seeded, 2 arms, 3 reps = **12 runs**.

### Scoring

    python3 score-run.py --manifest variants/manifest.json --arm new --verbose \
        run-new/seeded/*-output.md --control run-new/control/*-output.md

    python3 check-citations.py --repo <repo> --plan variants/seeded-plan.md \
        --verbose run*/*-output.md

Recall matching is keyword-based and **weak in both directions**. Every hit is a
candidate for your eye, not a verdict — `--verbose` prints the matching line so
confirming or rejecting takes seconds. That confirmation is the measurement.

**Do not let Claude score this.** The reviewers are Claude; a Claude judge
reintroduces exactly the self-preference bias the changes exist to guard against.
Score mechanically where possible, adjudicate the rest yourself, and use Codex as
a judge only if you must.

## Pre-registered decision rule

Write the rule down before looking at results, or you will rationalise whatever
happens.

> **Keep the change if:** control APPROVED rate improves materially (target: from
> 0/N to a clear majority), **and** seeded CRITICAL recall does not drop, **and**
> citation resolution stays at 100%.
>
> **Revert if:** seeded CRITICAL or MAJOR recall drops by more than one defect
> across the corpus, **or** citation resolution falls below 100%.
>
> **Inconclusive** — and say so rather than shipping — if the control APPROVED
> rate moves by less than half the runs. With N this small only large effects are
> real; 3/9 → 5/9 is noise.

Report as a sign test or bootstrap over paired differences. Do not compute a
t-test on n=5 and imply precision you do not have.

## Attribution

The calibration branch bundles ~10 changes, so an aggregate win says "keep it,"
not "why." Do not attempt a factorial — 2^10 is absurd. If upstreaming, ablate
only the two highest-risk levers separately:

1. **The severity threshold** — largest behavioural change; drives the round gate.
2. **The grounding clause** — already caused one production regression (it was
   sent to a reviewer with no repo, which killed the whole review).

## Not an eval: the smoke test you also want

Distinct from any of this. *Does every configured reviewer return exit 0 and
non-empty output on a trivial plan?* Two minutes, catches whole-reviewer failures,
and belongs in `tests/`. The antigravity regression above would have been caught
by it instantly. Quality evals are for deciding; smoke tests are for not shipping
something broken.
