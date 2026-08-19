#!/usr/bin/env python3
"""Score one bigdiff review transcript against the fixture's six known bugs.

Prints a single line: "<hits> <other> <bug-ids|->" for run_bigdiff.sh to read,
or exits EMPTY_LOG_EXIT when the transcript is empty and there is no score.

Scoring is by the QUOTE line, the same evidence the audit's own anti-fabrication
gate uses -- a finding that does not quote the offending line is not a catch.
"other" counts finding blocks matching no known bug; it is a fabrication
CANDIDATE count, not a fabrication count, because the fixture is real code and
more real bugs are possible -- the sixth (rename_prefix) was exactly that,
discovered by an arm 2026-08-19. Read logs/ before calling one a fabrication.
"""
import re
import sys

# An empty transcript is signalled by this EXIT CODE, not by a token in the
# output line, so run_bigdiff.sh can route it into the row's `status` column
# instead of `bugs`. The old "0 0 EMPTY-LOG" put a marker where readers parse
# bug ids while the two numeric columns beside it claimed a real measurement of
# zero -- which is why watch_ctx_tiers.py renders such a row as "0 known bugs",
# i.e. as a model result. Anything else non-zero stays SCORE-ERROR.
EMPTY_LOG_EXIT = 3

# (id, [quote substrings, any one matches], extra predicate over the block)
#
# A bug spanning two lines can be legitimately quoted from either end, and the
# quote is the only evidence the audit itself keeps -- so a signature list that
# names one end scores a real catch as an unmatched finding. Measured
# 2026-08-18: the import-after-guard bug was reported once against the
# registration line and once against the `__main__` guard it sits below.
BUGS = [
    ("cache_evict", ["victim = max(self._entries"], None),
    ("migrate_discard", ['_migrate_v1(payload["data"])'], None),
    # Either end of the same defect: the registration that never runs, or the
    # guard that returns before reaching it. The guard line is only about this
    # bug when the finding is actually discussing the import command.
    # The pred gates EVERY needle, so it must check what the bug actually is
    # (dead registration behind the __main__ guard), not merely that the topic
    # is "import" -- a finding quoting the def line is about import by
    # construction, and a pred that can't fail scores any defect at that line
    # as this bug while suppressing it from `other`.
    ("import_after_guard",
     ['COMMANDS["import"] = cmd_import', "sys.exit(main(sys.argv))",
      "def cmd_import(store, args):"],
     lambda b: "import" in b["body"].lower()
               and ("__main__" in b["body"] or "sys.exit" in b["body"].lower()
                    or "unreachable" in b["body"].lower()
                    or "never" in b["body"].lower())),
    ("export_default_ns", ["for key in store.keys():"], None),
    # Discovered (not planted) 2026-08-19 by the bold-finder arm and verified
    # by live probe: rename_namespace validates SEP only in `new`, so an `old`
    # containing SEP prefix-matches keys of a sibling namespace and moves them.
    ("rename_prefix",
     ["if SEP in new:", "old_prefix = old + SEP"],
     # Falsifiable on purpose: rename_namespace can host other complaints (e.g.
     # target-namespace overwrites) at these same lines. This bug is the
     # unvalidated-`old` prefix match, so the body must discuss that.
     lambda b: "store.py" in b["file"]
               and "prefix" in b["body"].lower()
               and ("match" in b["body"].lower()
                    or "valid" in b["body"].lower()
                    or "sibling" in b["body"].lower())),
    # `return 0` alone is ambiguous -- cmd_export ends with a CORRECT one and
    # cmd_keys/cmd_import carry more. Require the export path AND the error
    # context, so the correct trailing `return 0` (or an import-side finding
    # whose prose merely mentions export) is not credited as this bug.
    ("export_exit0", ["return 0"],
     lambda b: "cli.py" in b["file"] and "export" in b["body"].lower()
               and ("oserror" in b["body"].lower() or "error" in b["body"].lower()
                    or "fail" in b["body"].lower() or "except" in b["body"].lower())),
]


def normalize(s):
    """Match the audit's own quote normalization: drop a diff marker, collapse
    whitespace runs, strip backticks."""
    s = s.strip()
    if s[:1] in "+-":
        s = s[1:]
    return re.sub(r"\s+", " ", s.replace("`", "")).strip().lower()


def blocks(text):
    """Yield finding blocks. A block starts at a FILE: line and runs to the next
    one; the audit already rejects a verdict whose blocks are malformed, so this
    only needs to survive well-formed output."""
    out, cur = [], None
    for line in text.splitlines():
        if line.startswith("FILE:"):
            if cur:
                out.append(cur)
            cur = {"file": line[5:].strip(), "quote": "", "body": ""}
        elif cur is not None:
            if line.startswith("QUOTE:") and not cur["quote"]:
                cur["quote"] = line[6:]
            else:
                cur["body"] += line + "\n"
    if cur:
        out.append(cur)
    return out


def main():
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    # A --verify run appends a verification section that repeats each finding's
    # FILE: line (with the verdict, without a QUOTE). Those are review.sh's own
    # output, not findings -- parsing them inflated `other` by exactly the
    # finding count until 2026-08-19. Score only the review above the marker.
    text = text.split("--- verification (--verify) ---")[0]
    # An empty transcript is a run that has not finished (review.sh writes its
    # verdict at the end) or one that died. Scoring it as zero hits makes it
    # read identically to a clean review, which is the one confusion this
    # fixture exists to catch -- so say so instead.
    if not text.strip():
        print("EMPTY-LOG")
        return EMPTY_LOG_EXIT
    found, other = [], 0
    for b in blocks(text):
        q = normalize(b["quote"])
        if not q:
            other += 1
            continue
        for bug_id, needles, pred in BUGS:
            if any(normalize(n) in q for n in needles) and (pred is None or pred(b)):
                if bug_id not in found:
                    found.append(bug_id)
                break
        else:
            other += 1
    print(f"{len(found)} {other} {','.join(found) if found else '-'}")


if __name__ == "__main__":
    # main()'s return value is the exit status, which is how the empty-transcript
    # case reaches run_bigdiff.sh without putting a token in a scored column.
    # A normal score falls off the end of main(), so None -> 0 as before.
    sys.exit(main())
