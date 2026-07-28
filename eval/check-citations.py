#!/usr/bin/env python3
"""Check whether the file:line citations in a review actually resolve.

This is the one review-quality signal that needs no judgment and no model: a
citation either points at a real line of a real file, or it does not. It is the
direct measure of the failure mode the grounding rules target -- a reviewer
confidently critiquing code that is not there.

Usage:
    check-citations.py --repo <path> [--plan <plan.md>] <review.md> [review.md ...]
    check-citations.py --repo <path> --json <review.md> ...      # JSONL for aggregation

Exit status is always 0 unless the invocation itself was wrong: this is a
measurement tool, not a gate. A low resolution rate is a finding to report, not
a build to fail.

ON THE "MISSING" BUCKET -- read before quoting a number
-------------------------------------------------------
A citation that does not resolve is NOT automatically a hallucination. Plans
routinely propose files that do not exist yet, and a reviewer citing one is
behaving correctly. Pass --plan and the checker splits those out: a target the
plan itself introduces is classified PROPOSED rather than MISSING.

The honest headline metric is therefore not "resolution rate" but the two hard
buckets, which have no benign reading:

  BAD_LINE  -- the file exists and the cited line does not. Unambiguous: the
               reviewer produced a line number it could not have read.
  MISSING   -- the target does not exist and the plan never proposes it.

BAD_LINE is the strongest single signal in this harness. Weight it accordingly.
"""

import argparse
import json
import os
import re
import sys

# A citation's path must carry a plausible source extension. Anchoring on the
# extension (rather than on ":\d+") is what keeps arXiv ids, DOIs, timestamps,
# version strings, and "http://host:8080" out of the sample -- each of which
# matches a naive file:line regex and would silently inflate the denominator.
EXT = (
    r"py|js|mjs|cjs|ts|tsx|jsx|sh|bash|zsh|md|json|jsonl|toml|yaml|yml|go|rs|rb|"
    r"java|kt|swift|c|h|cc|cpp|hpp|cs|php|sql|txt|cfg|ini|conf|env|lock|xml|html|css|scss"
)

CITATION_RE = re.compile(
    r"(?<![\w/.-])"                      # not mid-token
    r"(?P<path>[\w.\-]+(?:/[\w.\-]+)*\.(?:" + EXT + r"))"
    r"(?::(?P<line>\d+)(?:-(?P<end>\d+))?)?"
    r"(?![\w])"
)

# Contexts where a path-like token is prose, not a citation.
URL_RE = re.compile(r"https?://\S+")
FENCE_RE = re.compile(r"```.*?```", re.DOTALL)


def strip_noise(text, keep_code_fences):
    """Remove URLs, and optionally fenced code, before scanning for citations.

    Fenced blocks are excluded by default: a reviewer quoting a diff or a config
    sample is reproducing the plan's text, not making a citation of its own.
    Counting those attributes the plan's claims to the reviewer.
    """
    text = URL_RE.sub(" ", text)
    if not keep_code_fences:
        text = FENCE_RE.sub(" ", text)
    return text


def plan_proposes(plan_text, path):
    """Does the plan itself introduce this path as something to be created?

    Deliberately generous. The cost of wrongly calling a citation PROPOSED is a
    slightly optimistic score; the cost of wrongly calling it MISSING is
    accusing a reviewer of hallucinating a file the plan told it to expect.
    Between those, err toward the reviewer.
    """
    if not plan_text:
        return False
    base = os.path.basename(path)
    for cand in {path, base}:
        if cand and cand in plan_text:
            return True
    return False


def count_lines(abs_path):
    try:
        with open(abs_path, "rb") as fh:
            return sum(1 for _ in fh)
    except (OSError, UnicodeDecodeError):
        return None


def classify(repo, plan_text, path, line, plan_path=None, plan_lines=None):
    """-> (verdict, detail).

    Verdicts: OK, BAD_LINE, PROPOSED, MISSING, UNREADABLE, PLAN_LINE, BAD_PLAN_LINE.

    `plan.md:N` is a citation INTO the plan under review, not into the repo, and
    it is correct reviewer behaviour. The plan lives in the ephemeral work dir
    (.tmp/ai-review-<id>/plan.md), which is deleted after the run, so resolving it
    against the repo root reports it missing -- scoring the reviewer's best habit
    as a hallucination. Measured on a real corpus this was 93 of 98 apparent
    failures in one review and would have put the headline resolution rate ~14
    points too low.
    """
    if os.path.basename(path) == "plan.md":
        if plan_lines is None:
            return "PLAN_LINE", "cites the plan under review (no --plan given to verify)"
        if line is None:
            return "PLAN_LINE", "cites the plan under review"
        if int(line) > plan_lines:
            return "BAD_PLAN_LINE", "plan has %d lines; cited %s" % (plan_lines, line)
        return "PLAN_LINE", "plan line %s within %d" % (line, plan_lines)

    abs_path = os.path.join(repo, path)

    if not os.path.isfile(abs_path):
        # Try a basename match anywhere in the repo before declaring it missing:
        # reviewers often cite "ingest.py" for "ingest/ingest.py", which is a
        # loose citation, not an invented one.
        base = os.path.basename(path)
        for root, dirs, files in os.walk(repo):
            dirs[:] = [d for d in dirs if d not in
                       {".git", "node_modules", ".venv", "venv", "__pycache__", ".tmp"}]
            if base in files:
                abs_path = os.path.join(root, base)
                break
        else:
            if plan_proposes(plan_text, path):
                return "PROPOSED", "not on disk; plan introduces this path"
            return "MISSING", "not on disk; plan does not mention it"

    if line is None:
        return "OK", "file exists (no line cited)"

    total = count_lines(abs_path)
    if total is None:
        return "UNREADABLE", "file exists but could not be read"
    if int(line) > total:
        return "BAD_LINE", "file has %d lines; cited %s" % (total, line)
    return "OK", "line %s within %d" % (line, total)


def scan(review_path, repo, plan_text, keep_code_fences, plan_lines=None):
    try:
        with open(review_path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        return None, exc

    text = strip_noise(text, keep_code_fences)

    seen = set()
    results = []
    for m in CITATION_RE.finditer(text):
        path = m.group("path")
        line = m.group("line")
        key = (path, line)
        if key in seen:            # count each distinct citation once
            continue
        seen.add(key)
        verdict, detail = classify(repo, plan_text, path, line, plan_lines=plan_lines)
        results.append({
            "citation": path + (":" + line if line else ""),
            "path": path,
            "line": int(line) if line else None,
            "verdict": verdict,
            "detail": detail,
        })
    return results, None


def summarize(results):
    counts = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    total = len(results)
    # Resolvable denominator excludes PROPOSED: a not-yet-created file is
    # neither a hit nor a miss for the reviewer's grounding.
    gradable = (total - counts.get("PROPOSED", 0)
                - counts.get("PLAN_LINE", 0) - counts.get("BAD_PLAN_LINE", 0))
    ok = counts.get("OK", 0)
    rate = (ok / gradable * 100) if gradable else None
    return {
        "citations": total,
        "gradable": gradable,
        "ok": ok,
        "bad_line": counts.get("BAD_LINE", 0),
        "missing": counts.get("MISSING", 0),
        "proposed": counts.get("PROPOSED", 0),
        "unreadable": counts.get("UNREADABLE", 0),
        "plan_line": counts.get("PLAN_LINE", 0),
        "bad_plan_line": counts.get("BAD_PLAN_LINE", 0),
        "resolution_rate": rate,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reviews", nargs="+", help="review markdown file(s)")
    ap.add_argument("--repo", required=True, help="repo root the citations refer to")
    ap.add_argument("--plan", help="plan.md, to classify not-yet-created files as PROPOSED")
    ap.add_argument("--json", action="store_true", help="emit JSONL, one object per review")
    ap.add_argument("--verbose", action="store_true", help="list every non-OK citation")
    ap.add_argument("--keep-code-fences", action="store_true",
                    help="also scan fenced code blocks (off by default; they quote the plan)")
    args = ap.parse_args()

    repo = os.path.abspath(os.path.expanduser(args.repo))
    if not os.path.isdir(repo):
        print("error: --repo is not a directory: %s" % repo, file=sys.stderr)
        return 2

    plan_text = ""
    if args.plan:
        try:
            with open(args.plan, "r", encoding="utf-8", errors="replace") as fh:
                plan_text = fh.read()
        except OSError as exc:
            print("error: could not read --plan: %s" % exc, file=sys.stderr)
            return 2

    plan_lines = None
    if plan_text:
        plan_lines = plan_text.count("\n") + (0 if plan_text.endswith("\n") else 1)

    grand = []
    for review in args.reviews:
        results, err = scan(review, repo, plan_text, args.keep_code_fences, plan_lines)
        if err:
            print("error: %s: %s" % (review, err), file=sys.stderr)
            continue
        s = summarize(results)
        grand.extend(results)

        if args.json:
            print(json.dumps({"review": review, **s,
                              "citations_detail": results}, sort_keys=True))
            continue

        rate = "n/a" if s["resolution_rate"] is None else "%.0f%%" % s["resolution_rate"]
        print("%-52s %3d cited  %s resolved  %d bad-line  %d missing  %d plan-ref"
              % (os.path.basename(review)[:52], s["citations"], rate,
                 s["bad_line"], s["missing"], s["plan_line"] + s["bad_plan_line"]))
        if args.verbose:
            for r in results:
                if r["verdict"] != "OK":
                    print("      %-9s %-44s %s" % (r["verdict"], r["citation"], r["detail"]))

    if not args.json and len(args.reviews) > 1:
        g = summarize(grand)
        rate = "n/a" if g["resolution_rate"] is None else "%.1f%%" % g["resolution_rate"]
        print("-" * 100)
        print("TOTAL: %d citations across %d reviews | %d gradable | resolved %s"
              % (g["citations"], len(args.reviews), g["gradable"], rate))
        print("       hard failures: %d bad-line, %d missing"
              % (g["bad_line"], g["missing"]))
        print("       excluded from denominator: %d proposed-not-yet-created, %d plan self-refs"
              % (g["proposed"], g["plan_line"] + g["bad_plan_line"]))
        if g["bad_plan_line"]:
            print("       NOTE: %d citation(s) point past the end of the plan itself"
                  % g["bad_plan_line"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
