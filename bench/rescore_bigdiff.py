#!/usr/bin/env python3
"""Recompute the hits/other/bugs columns of results-bigdiff.tsv from the logs.

Scoring rules get corrected mid-benchmark -- a real catch quoted from an
unexpected line looks like an unmatched finding until the signature list is
widened. When that happens, the rows already written were scored by the old
rules and the rows still to come will be scored by the new ones, which is the
one thing a comparison across arms cannot survive.

The verdict transcripts in logs/ are the durable evidence; the TSV is a
derived cache. This rebuilds it, so every row in the file reflects whatever
score_bigdiff.py says today.

  python3 bench/rescore_bigdiff.py           # rewrite in place
  python3 bench/rescore_bigdiff.py --check   # report drift, change nothing
"""
import pathlib
import subprocess
import sys

BENCH = pathlib.Path(__file__).resolve().parent
RESULTS = BENCH / "results-bigdiff.tsv"
SCORER = BENCH / "score_bigdiff.py"


def main():
    check = "--check" in sys.argv
    lines = RESULTS.read_text().splitlines()
    if not lines:
        print("no results file")
        return 1

    head = lines[0].split("\t")
    idx = {name: i for i, name in enumerate(head)}
    out = [lines[0]]
    changed = 0

    seen = set()
    for line in lines[1:]:
        if not line.strip():
            continue
        cols = line.split("\t")
        label, run = cols[idx["label"]], cols[idx["run"]]
        # run_bigdiff.sh appends; a re-run under an old label leaves two rows
        # sharing one log path. Rescoring both from the same transcript would
        # turn two observations into two identical ones -- rescore only the
        # last (the one the current log belongs to) and say so.
        if (label, run) in seen:
            print(f"  duplicate row {label} run {run}: only the LAST one is "
                  f"backed by the log; earlier duplicate left as-is")
        log = BENCH / "logs" / f"{label}-bigdiff-r{run}.txt"
        if (label, run) in seen or not log.exists() or log.stat().st_size == 0:
            # No usable transcript, no rescore -- keep the row rather than
            # silently zeroing a result whose evidence was truncated or
            # cleaned up. (A zero-byte log is a truncation artifact, not a
            # run that produced nothing: the row it orphans was scored from
            # the log's earlier contents. Measured 2026-08-18: an aborted
            # same-label relaunch truncated a 5/5 run's log and a rescore
            # rewrote the row to EMPTY-LOG.)
            if not (label, run) in seen:
                print(f"  no usable log for {label} run {run}, left as-is")
            seen.add((label, run))
            out.append(line)
            continue
        seen.add((label, run))

        res = subprocess.run([sys.executable, str(SCORER), str(log)],
                             capture_output=True, text=True)
        if res.returncode != 0 or not res.stdout.strip():
            # One bad transcript must not abort the pass and leave the file
            # half-rescored under two rule sets.
            print(f"  scorer FAILED for {label} run {run} "
                  f"(rc {res.returncode}), left as-is")
            out.append(line)
            continue
        hits, other, bugs = res.stdout.strip().split(" ", 2)
        before = (cols[idx["hits"]], cols[idx["other"]], cols[idx["bugs"]])
        after = (hits, other, bugs)
        if before != after:
            changed += 1
            print(f"  {label} run {run}: "
                  f"hits {before[0]}->{after[0]}, other {before[1]}->{after[1]}")
            print(f"    bugs {before[2]}")
            print(f"      -> {after[2]}")
        cols[idx["hits"]], cols[idx["other"]], cols[idx["bugs"]] = after
        out.append("\t".join(cols))

    if check:
        print(f"{changed} row(s) would change")
        return 0
    RESULTS.write_text("\n".join(out) + "\n")
    print(f"rewrote {RESULTS.name}: {changed} row(s) changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
