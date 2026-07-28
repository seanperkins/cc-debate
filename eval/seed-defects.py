#!/usr/bin/env python3
"""Inject known defects into a plan, producing ground truth to score reviews against.

The hard part of evaluating a reviewer is that nobody knows which findings are
real. Seeding sidesteps it: put a defect in yourself and you know exactly what is
there, what severity it deserves, and which reviewer should have caught it.

    seed-defects.py --plan plan.md --out-dir variants/ [--defects id1,id2]
    seed-defects.py --list

Produces, in --out-dir:
    seeded-plan.md   the plan with defects appended
    manifest.json    what was injected, where, expected severity and lane

WHY THE DEFECTS ARE ADDITIVE
----------------------------
Each defect is appended as a plausible new subsection rather than spliced into
existing prose. Splicing needs per-plan anchors, breaks on the next plan, and
risks silently mangling the text so the review is scored against a plan that no
longer says what the manifest claims. Appending is portable across any plan and
keeps the manifest honest. The cost is that a very attentive reviewer might
notice the new sections read as bolted on -- acceptable, since we are measuring
whether it catches the *defect*, not whether it detects tampering.

THE CONTROL MATTERS MORE THAN THE SEEDS
---------------------------------------
Always also run the UNSEEDED plan. The primary claim of the calibration work is
that reviewers stop manufacturing findings; the only way to observe that is a
plan with nothing planted in it. A high seeded-recall score with a control that
still returns REVISE means precision did not improve -- the reviewer is simply
finding everything, which is what it did before.
"""

import argparse
import json
import os
import sys

# Each defect: plausible prose a real plan might contain, carrying exactly one
# fault whose severity is defensible under the CRITICAL/MAJOR/MINOR definitions
# in the reviewer footer. `lane` records which persona ought to own it, so a
# miss can be attributed rather than just counted.
DEFECTS = [
    {
        "id": "secret-log",
        "severity": "CRITICAL",
        "lane": "pentester",
        "title": "Debug logging for auth failures",
        "text": (
            "### Debug logging for auth failures\n\n"
            "When token refresh fails, log the full credential payload -- including the\n"
            "refresh token and client secret -- at ERROR level so the failure can be\n"
            "diagnosed from the production log aggregator without reproducing locally.\n"
        ),
        "expect": "credentials/secrets written to logs",
    },
    {
        "id": "shell-injection",
        "severity": "CRITICAL",
        "lane": "pentester",
        "title": "Attachment scanning hook",
        "text": (
            "### Attachment scanning hook\n\n"
            "For each attachment, invoke the local scanner by building the command as\n"
            "`subprocess.run(f\"scan --file {attachment.filename}\", shell=True)`. The\n"
            "filename comes straight from the message metadata, which keeps the hook\n"
            "simple and avoids maintaining an argument list.\n"
        ),
        "expect": "untrusted filename interpolated into a shell string",
    },
    {
        "id": "off-by-one",
        "severity": "MAJOR",
        "lane": "skeptic",
        "title": "Batch submission",
        "text": (
            "### Batch submission\n\n"
            "Submit episodes to the graph in batches of 100: iterate with\n"
            "`for i in range(0, len(episodes), 100)` and submit the slice\n"
            "`episodes[i:i + 99]` on each pass.\n"
        ),
        "expect": "slice drops one item per batch (i+99 should be i+100)",
    },
    {
        "id": "no-cursor",
        "severity": "MAJOR",
        "lane": "operator",
        "title": "Scheduling",
        "text": (
            "### Scheduling\n\n"
            "Run the ingestion hourly via cron. Each run queries the full configured\n"
            "history window and re-evaluates every message found; no cursor or\n"
            "high-water mark is persisted between runs.\n"
        ),
        "expect": "unbounded rescan every run; no incremental state",
    },
    {
        "id": "dangling-retry-ref",
        "severity": "MAJOR",
        "lane": "skeptic",
        "title": "Transient failure handling",
        "text": (
            "### Transient failure handling\n\n"
            "On a transient API error, the fetcher retries according to the retry and\n"
            "backoff policy described above, then surfaces the failure to the caller.\n"
        ),
        "expect": "cites a retry/backoff policy the plan never defines",
        "note": "tests the category-(b) 'plan is silent on a required decision' clause",
    },
    {
        "id": "fabricated-citation",
        "severity": "MAJOR",
        "lane": "any",
        "title": "Precedent",
        "text": (
            "### Precedent\n\n"
            "This mirrors the existing incremental sync already implemented in\n"
            "`ingest/legacy_sync.py:412`, and reuses the same checkpoint semantics as\n"
            "`ingest/checkpoint_store.py`.\n"
        ),
        "expect": "cites files/lines that do not exist in the repo",
        "note": "tests the grounding clause; requires a reviewer with repo access",
    },
    {
        "id": "flag-name-drift",
        "severity": "MINOR",
        "lane": "skeptic",
        "title": "Dry-run support",
        "text": (
            "### Dry-run support\n\n"
            "Add a `--dry-run` flag that reports what would be ingested without\n"
            "writing. Example invocation: `python -m ingest --dryrun --source mail`.\n"
        ),
        "expect": "flag spelled --dry-run in prose and --dryrun in the example",
        "note": "MUST NOT block approval under the new severity rule",
    },
]

BY_ID = {d["id"]: d for d in DEFECTS}


def build(plan_text, chosen):
    parts = [plan_text.rstrip(), "", "---", "", "## Implementation details", ""]
    placed = []
    for d in chosen:
        start_line = plan_text.count("\n") + len(parts)  # approximate, for reference only
        parts.append(d["text"])
        placed.append({
            "id": d["id"],
            "severity": d["severity"],
            "lane": d["lane"],
            "section": d["title"],
            "expect": d["expect"],
            "note": d.get("note", ""),
            "approx_section_order": len(placed) + 1,
        })
    return "\n".join(parts) + "\n", placed


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", help="source plan markdown")
    ap.add_argument("--out-dir", help="directory to write seeded-plan.md and manifest.json")
    ap.add_argument("--defects", help="comma-separated ids (default: all)")
    ap.add_argument("--list", action="store_true", help="list available defects and exit")
    args = ap.parse_args()

    if args.list:
        print("%-22s %-9s %-10s %s" % ("ID", "SEVERITY", "LANE", "WHAT IS WRONG"))
        for d in DEFECTS:
            print("%-22s %-9s %-10s %s" % (d["id"], d["severity"], d["lane"], d["expect"]))
            if d.get("note"):
                print("%-44s   note: %s" % ("", d["note"]))
        return 0

    if not args.plan or not args.out_dir:
        ap.error("--plan and --out-dir are required unless --list is given")

    try:
        with open(args.plan, "r", encoding="utf-8") as fh:
            plan_text = fh.read()
    except OSError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2

    if args.defects:
        ids = [i.strip() for i in args.defects.split(",") if i.strip()]
        unknown = [i for i in ids if i not in BY_ID]
        if unknown:
            print("error: unknown defect id(s): %s" % ", ".join(unknown), file=sys.stderr)
            print("       run --list to see available ids", file=sys.stderr)
            return 2
        chosen = [BY_ID[i] for i in ids]
    else:
        chosen = DEFECTS

    seeded, placed = build(plan_text, chosen)

    os.makedirs(args.out_dir, exist_ok=True)
    seeded_path = os.path.join(args.out_dir, "seeded-plan.md")
    control_path = os.path.join(args.out_dir, "control-plan.md")
    manifest_path = os.path.join(args.out_dir, "manifest.json")

    with open(seeded_path, "w", encoding="utf-8") as fh:
        fh.write(seeded)
    # The control is the untouched plan, written alongside so the pair is
    # obviously a pair and nobody scores a seeded run against a different source.
    with open(control_path, "w", encoding="utf-8") as fh:
        fh.write(plan_text)
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump({
            "source_plan": os.path.abspath(args.plan),
            "seeded_plan": os.path.abspath(seeded_path),
            "control_plan": os.path.abspath(control_path),
            "defects": placed,
            "counts": {
                "CRITICAL": sum(1 for d in placed if d["severity"] == "CRITICAL"),
                "MAJOR": sum(1 for d in placed if d["severity"] == "MAJOR"),
                "MINOR": sum(1 for d in placed if d["severity"] == "MINOR"),
            },
        }, fh, indent=2)

    print("seeded plan : %s" % seeded_path)
    print("control plan: %s   <- run this too; it is the precision test" % control_path)
    print("manifest    : %s" % manifest_path)
    print("injected    : %d defects (%d CRITICAL, %d MAJOR, %d MINOR)"
          % (len(placed),
             sum(1 for d in placed if d["severity"] == "CRITICAL"),
             sum(1 for d in placed if d["severity"] == "MAJOR"),
             sum(1 for d in placed if d["severity"] == "MINOR")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
