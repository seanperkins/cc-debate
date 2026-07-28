#!/usr/bin/env python3
"""Assemble a Claude reviewer prompt from one arm's own source files.

    build-prompt.py --arm <dir> --persona "Opus Skeptic" --plan plan.md [--roster "..."]

The Claude side of the panel is normally driven by slash-command markdown that an
orchestrator interprets, which makes it awkward to A/B. This reconstructs the same
prompt the orchestrator would build -- persona body from `scripts/reviewer-prompts.md`,
shared footer from `commands/run.md` -- so both arms can be run headlessly and
compared without a checkout dance.

WHAT THIS DOES AND DOES NOT MEASURE
-----------------------------------
It isolates the REVIEWER PROMPT, which is the variable under test. It does not
exercise the orchestration around it: the round gate, synthesis weighting, the
debate phase, or the respawn logic are all bypassed. A win here is evidence about
prompts, not about the whole pipeline. Test orchestration separately, by hand.

THE HARNESS OVERRIDE
--------------------
The production footer tells the reviewer to deliver by writing a file and pinging
the orchestrator's mailbox. Neither exists under `claude --print`, so a trailing
override redirects delivery to stdout. It is appended VERBATIM AND IDENTICALLY to
both arms, so it cannot favour either -- but it is a deviation from production and
is printed in full by --show-override so nobody has to take that on trust.
"""

import argparse
import os
import re
import sys

PERSONAS = ["Fable Skeptic", "Opus Skeptic", "Solo Skeptic",
            "Simplifier", "Operator", "Pentester", "Architect"]

# Metadata lines that sit under a persona heading but are not part of the body.
META_RE = re.compile(r"^(name:|model:|\(config:|\(used for|\(the generic body)")

OVERRIDE = """

HARNESS OVERRIDE (evaluation run — this section wins over any conflicting
instruction above): You are running headless with no orchestrator and no mailbox.
Ignore any instruction above to write your review to a file or to SendMessage
anything. Print your complete review — every finding plus the final VERDICT line —
to stdout. That printed text is your entire deliverable.
"""


def extract_persona(arm_dir, persona):
    path = os.path.join(arm_dir, "scripts", "reviewer-prompts.md")
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    want = "## " + persona
    body, capturing = [], False
    for ln in lines:
        if ln.strip() == want:
            capturing = True
            continue
        if capturing:
            # A persona section ends at the next heading or horizontal rule.
            if ln.startswith("## ") or ln.strip() == "---":
                break
            if META_RE.match(ln.strip()):
                continue
            body.append(ln)
    if not capturing:
        raise SystemExit("error: persona %r not found in %s\n       available: %s"
                         % (persona, path, ", ".join(PERSONAS)))
    return "\n".join(body).strip()


def extract_footer(arm_dir):
    """First fenced block after the '**Shared reviewer footer.**' marker."""
    path = os.path.join(arm_dir, "commands", "run.md")
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    seen_marker = False
    fence = 0
    block = []
    for ln in lines:
        if "**Shared reviewer footer.**" in ln:
            seen_marker = True
            continue
        if not seen_marker:
            continue
        if ln.strip() == "```":
            fence += 1
            if fence == 1:
                continue
            break
        if fence == 1:
            block.append(ln)
    if not block:
        raise SystemExit("error: could not extract the shared footer from %s" % path)

    # The footer is indented inside the fence; strip the common indent.
    non_empty = [l for l in block if l.strip()]
    indent = min((len(l) - len(l.lstrip())) for l in non_empty) if non_empty else 0
    return "\n".join(l[indent:] if len(l) >= indent else l for l in block).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm", required=True, help="arm directory (from setup-arms.sh)")
    ap.add_argument("--persona", required=True, help='e.g. "Opus Skeptic"')
    ap.add_argument("--plan", required=True)
    ap.add_argument("--roster", default="none",
                    help="other reviewers this round, for [PANEL_ROSTER] (new arm only)")
    ap.add_argument("--output-path", default="/dev/null",
                    help="value for [OUTPUT_PATH]; delivery is overridden to stdout anyway")
    ap.add_argument("--show-override", action="store_true",
                    help="print the harness override text and exit")
    args = ap.parse_args()

    if args.show_override:
        print(OVERRIDE.strip())
        return 0

    with open(args.plan, "r", encoding="utf-8") as fh:
        plan = fh.read()

    body = extract_persona(args.arm, args.persona)
    footer = extract_footer(args.arm)

    # [PANEL_ROSTER] exists only in the new arm; .replace on the old arm is a
    # harmless no-op, which is what keeps one assembler valid for both.
    footer = (footer
              .replace("[CURRENT_PLAN]", plan)
              .replace("[OUTPUT_PATH]", args.output_path)
              .replace("[PANEL_ROSTER]", args.roster))

    sys.stdout.write(body + "\n\n" + footer + "\n" + OVERRIDE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
