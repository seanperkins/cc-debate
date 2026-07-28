#!/usr/bin/env python3
"""Score a set of reviews against a seeded-defect manifest.

    score-run.py --manifest variants/manifest.json --arm new --control <dir> <review.md>...

Reports, per arm:
  recall        which seeded defects were found, by severity and by lane
  calibration   assigned severity vs. planted severity
  verdict       APPROVED / REVISE, and whether that was the correct call
  format        how often findings carry Confidence and Disproof
  volume        findings per review (context only -- NOT a quality metric)

WHAT THIS TOOL DOES AND DOES NOT DECIDE
---------------------------------------
Recall is matched by keyword, which is a weak matcher: it can miss a reviewer
that described a defect in different words (undercounting recall) and can fire on
a passing mention that drew no conclusion (overcounting). Treat every recall
number as a CANDIDATE for your eye, not a verdict. `--verbose` prints the
matching line from the review so a human can confirm or reject each hit in
seconds; that confirmation is the real measurement.

The one number here that needs no judgment is the CONTROL verdict: on a plan with
nothing planted, APPROVED is correct and REVISE is a false positive. That is the
primary metric of the calibration work, and it is why --control is not optional.

DO NOT let a model score this. The obvious shortcut -- ask Claude whether the
reviews got better -- reintroduces the self-preference bias the changes exist to
guard against, since the reviewers are themselves Claude.
"""

import argparse
import json
import os
import re
import sys

# Keyword sets per defect id. Deliberately broad: a false hit is visible in
# --verbose and costs seconds to reject, while a false miss silently understates
# a reviewer that did its job.
MATCHERS = {
    "secret-log":          [r"secret", r"credential", r"refresh token", r"log.{0,20}token",
                            r"token.{0,20}log", r"pii", r"redact"],
    "shell-injection":     [r"shell\s*=\s*true", r"injection", r"subprocess", r"shell string",
                            r"untrusted.{0,30}(filename|input)", r"command injection"],
    "off-by-one":          [r"off.by.one", r"i\s*\+\s*99", r"\[i:i\s*\+\s*99\]", r"drops? one",
                            r"99", r"batch.{0,30}(size|boundary)"],
    "no-cursor":           [r"cursor", r"high.water", r"incremental", r"checkpoint",
                            r"re-?scan", r"full history", r"idempot"],
    # NOTE: every pattern here must imply the retry/backoff gap specifically. An
    # earlier version included a bare r"silent", which fired on any finding using
    # the word "silently" -- it matched the off-by-one finding and scored a miss
    # as a hit. Keep these anchored to the defect, not to reviewer vocabulary.
    "dangling-retry-ref":  [r"retry", r"backoff",
                            r"polic(y|ies).{0,40}(never|not).{0,20}(defined|specified|described)",
                            r"(never|not) (defined|specified|described).{0,40}polic"],
    "fabricated-citation": [r"legacy_sync", r"checkpoint_store", r"does not exist",
                            r"could not (find|verify|confirm)", r"fabricat", r"no such file"],
    "flag-name-drift":     [r"dryrun", r"dry-run", r"inconsisten", r"spelling", r"mismatch"],
}

SEVERITY_RE = re.compile(r"\b(CRITICAL|MAJOR|MINOR)\b")
VERDICT_RE = re.compile(r"VERDICT:\s*(APPROVED|REVISE)", re.IGNORECASE)
CONFIDENCE_RE = re.compile(r"\b(CONFIRMED|LIKELY|HYPOTHESIS)\b")
DISPROOF_RE = re.compile(r"disproof", re.IGNORECASE)
# A finding heading: "### [MAJOR] ..." or "- **CRITICAL**" etc. Loose on purpose.
FINDING_RE = re.compile(r"^\s*(?:#{2,4}\s*|\-\s*|\*\s*)?\[?\*{0,2}(CRITICAL|MAJOR|MINOR)\*{0,2}\]?",
                        re.MULTILINE)


def load(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def find_defect(text, defect_id):
    """-> (hit: bool, evidence: str). Evidence is the first matching line."""
    pats = MATCHERS.get(defect_id, [])
    lines = text.split("\n")
    for pat in pats:
        rx = re.compile(pat, re.IGNORECASE)
        for ln in lines:
            if rx.search(ln):
                return True, ln.strip()[:120]
    return False, ""


def nearest_severity(text, evidence):
    """Severity label governing the evidence line: the last one AT OR BEFORE it.

    Looks strictly backward. An earlier version also scanned 200 chars forward,
    which let the *next* finding's label win whenever the evidence sat near the
    end of its own section -- a CRITICAL finding was scored as MAJOR because the
    following heading fell inside the window. Severity labels precede their
    findings, so only the backward direction is meaningful.
    """
    if not evidence:
        return None
    idx = text.find(evidence[:60])
    if idx < 0:
        return None
    window = text[max(0, idx - 600):idx]
    m = SEVERITY_RE.findall(window)
    return m[-1] if m else None


def score_review(path, manifest, verbose):
    text = load(path)
    name = os.path.basename(path)

    verdict_m = VERDICT_RE.search(text)
    verdict = verdict_m.group(1).upper() if verdict_m else "NONE"

    findings = len(FINDING_RE.findall(text))
    has_conf = len(CONFIDENCE_RE.findall(text))
    has_disproof = len(DISPROOF_RE.findall(text))

    hits = {}
    for d in manifest["defects"]:
        hit, ev = find_defect(text, d["id"])
        sev = nearest_severity(text, ev) if hit else None
        hits[d["id"]] = {"hit": hit, "evidence": ev, "assigned_severity": sev,
                         "planted_severity": d["severity"], "lane": d["lane"]}
        if verbose and hit:
            flag = "" if sev == d["severity"] else "  <-- severity mismatch" if sev else ""
            print("      %-22s planted=%-8s assigned=%-8s%s"
                  % (d["id"], d["severity"], sev or "?", flag))
            print("        %s" % ev)
        elif verbose and not hit:
            print("      %-22s planted=%-8s MISSED" % (d["id"], d["severity"]))

    return {"review": name, "verdict": verdict, "findings": findings,
            "confidence_labels": has_conf, "disproof_mentions": has_disproof,
            "hits": hits}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reviews", nargs="*", help="review files for the SEEDED plan")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--arm", default="unnamed", help="label, e.g. old / new")
    ap.add_argument("--control", nargs="*", default=[],
                    help="review files for the CONTROL (unseeded) plan -- the precision test")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open(args.manifest, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    print("=" * 78)
    print("ARM: %s" % args.arm)
    print("=" * 78)

    seeded = []
    if args.reviews:
        print("\nSEEDED PLAN  (%d planted: %s)"
              % (len(manifest["defects"]),
                 ", ".join("%s=%s" % (d["id"], d["severity"]) for d in manifest["defects"])))
        for r in args.reviews:
            if args.verbose:
                print("\n  %s" % os.path.basename(r))
            seeded.append(score_review(r, manifest, args.verbose))

        # Union recall: the panel as a whole is what matters, not any one reviewer.
        print("\n  PANEL RECALL (any reviewer found it):")
        for d in manifest["defects"]:
            found_by = [s["review"] for s in seeded if s["hits"][d["id"]]["hit"]]
            mark = "FOUND" if found_by else "MISSED"
            print("    %-8s %-22s %-6s  %s"
                  % (d["severity"], d["id"], mark,
                     ("by %d/%d reviewers" % (len(found_by), len(seeded))) if found_by else ""))
        crit = [d for d in manifest["defects"] if d["severity"] == "CRITICAL"]
        crit_found = sum(1 for d in crit
                         if any(s["hits"][d["id"]]["hit"] for s in seeded))
        print("\n    CRITICAL recall: %d/%d" % (crit_found, len(crit)))

    if args.control:
        print("\nCONTROL PLAN (nothing planted -- APPROVED is the correct verdict)")
        approved = 0
        for c in args.control:
            s = score_review(c, manifest, False)
            ok = "correct" if s["verdict"] == "APPROVED" else "FALSE POSITIVE"
            if s["verdict"] == "APPROVED":
                approved += 1
            print("    %-46s %-9s %-15s (%d findings)"
                  % (os.path.basename(c)[:46], s["verdict"], ok, s["findings"]))
        print("\n    CONTROL APPROVED RATE: %d/%d   <-- the primary metric"
              % (approved, len(args.control)))
    else:
        print("\n  WARNING: no --control reviews given. Seeded recall alone cannot show")
        print("           whether precision improved -- a reviewer that flags everything")
        print("           scores perfect recall. Run the control plan too.")

    if args.json:
        print("\n" + json.dumps({"arm": args.arm, "seeded": seeded}, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
