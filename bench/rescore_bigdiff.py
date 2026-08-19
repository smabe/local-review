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
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

BENCH = pathlib.Path(__file__).resolve().parent
RESULTS = BENCH / "results-bigdiff.tsv"
SCORER = BENCH / "score_bigdiff.py"

# Where each pre-existing column sat before the 2026-08-19 migration, which
# only ever APPENDED (status date sha vsurv vtotal). Positions are what this
# script trusts to rewrite a row, so a column that moved would make it write
# every score into the wrong cell -- silently, since every value is a plain
# string. Checked once per run against the live header; see
# docs/bench-hardening-spec.md, "Canonical schema".
HISTORICAL_INDEX = {
    "label": 0, "run": 1, "exit": 2, "secs": 3,
    "nfind": 4, "hits": 5, "other": 6, "bugs": 7,
}
# A row narrower than the pre-migration width is truncated, not old: every row
# ever written carried all eight of these.
NARROWEST = len(HISTORICAL_INDEX)

# The `status` values that describe the SCORING rather than the run, and so are
# retired by a successful rescore. Everything else in that column (SUSPECT, and
# the terminal SERVER-DOWN / LOCKED) is a fact about the run itself.
SCORING_MARKERS = ("SCORE-ERROR", "EMPTY-LOG")


def cell(cols, idx, name):
    """One field, empty when the row predates the column.

    The file is legitimately mixed-width from the migration commit forward:
    the header carries the new names and the historical rows do not. A missing
    field says "this row predates the column", which is the true fact; writing
    a blank onto it would assert "no data" for runs whose data still exists in
    bench/logs/*.err.
    """
    i = idx[name]
    return cols[i] if i < len(cols) else ""


def main():
    check = "--check" in sys.argv
    lines = RESULTS.read_text().splitlines()
    if not lines:
        print("no results file")
        return 1

    head = lines[0].split("\t")
    idx = {name: i for i, name in enumerate(head)}
    for name, want in sorted(HISTORICAL_INDEX.items(), key=lambda kv: kv[1]):
        got = idx.get(name)
        if got != want:
            sys.stderr.write(
                f"header corrupt: column '{name}' is at index {got}, expected "
                f"{want}. New columns append at the END only -- an insert or a "
                f"reorder shifts every stored score. Refusing to rewrite "
                f"{RESULTS.name}.\n")
            return 1
    out = [lines[0]]
    changed = 0

    # run_bigdiff.sh appends; a re-run under an old label leaves two rows
    # sharing one log path, and the log on disk belongs to the LATEST run.
    # Pre-pass: mark which row index owns each log, so only that row is
    # rescored from it. (A first-pass `seen` guard gets this exactly
    # backwards -- rows walk in file order, so the FIRST occurrence falls
    # through to the rescore and the older observation is overwritten with
    # the newer run's findings. Measured 2026-08-18 by the benchmark
    # session, against this very file.)
    #
    # Keyed on (label, run) and NOT on date: a rescored row keeps the date it
    # was measured on, so folding date into the key would make every rescore
    # look like a new row.
    data = [ln for ln in lines[1:] if ln.strip()]
    owner = {}
    for i, ln in enumerate(data):
        cols = ln.split("\t")
        if len(cols) < NARROWEST:
            continue
        owner[(cell(cols, idx, "label"), cell(cols, idx, "run"))] = i

    for i, line in enumerate(data):
        cols = line.split("\t")
        # A truncated row still yields a label and a run, so it would reach the
        # scorer and then die on the positional write-back below -- aborting the
        # whole pass and leaving the file half-rescored under two rule sets,
        # which is the one outcome every other guard here exists to prevent.
        if len(cols) < NARROWEST:
            print(f"  data row {i + 1} has {len(cols)} of {NARROWEST} original "
                  f"columns -- truncated, left as-is")
            out.append(line)
            continue
        label, run = cell(cols, idx, "label"), cell(cols, idx, "run")
        if owner[(label, run)] != i:
            print(f"  duplicate row {label} run {run}: the log belongs to the "
                  f"LAST occurrence; this earlier observation left as-is")
            out.append(line)
            continue
        log = BENCH / "logs" / f"{label}-bigdiff-r{run}.txt"
        if not log.exists() or log.stat().st_size == 0:
            # No usable transcript, no rescore -- keep the row rather than
            # silently zeroing a result whose evidence was truncated or
            # cleaned up. (A zero-byte log is a truncation artifact, not a
            # run that produced nothing: the row it orphans was scored from
            # the log's earlier contents. Measured 2026-08-18: an aborted
            # same-label relaunch truncated a 5/5 run's log and a rescore
            # rewrote the row to EMPTY-LOG.)
            print(f"  no usable log for {label} run {run}, left as-is")
            out.append(line)
            continue

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
        before = (cell(cols, idx, "hits"), cell(cols, idx, "other"),
                  cell(cols, idx, "bugs"))
        after = (hits, other, bugs)
        # A scoring marker describes the SCORE, and this row has just been
        # scored, so the marker is spent -- leaving it would make
        # watch_ctx_tiers.py's status gate hide the very numbers restored
        # below. SUSPECT and the two terminal markers describe the RUN, which
        # no amount of re-scoring resolves, so they are not the scorer's to
        # clear. Guarded on the cell existing at all: a pre-migration row is
        # narrower than the header and has no status column to touch.
        si = idx.get("status")
        retire = (si is not None and si < len(cols)
                  and cols[si] in SCORING_MARKERS)
        if before != after:
            changed += 1
            print(f"  {label} run {run}: "
                  f"hits {before[0]}->{after[0]}, other {before[1]}->{after[1]}")
            print(f"    bugs {before[2]}")
            print(f"      -> {after[2]}")
        if retire:
            # Counted too, or --check would report "0 rows would change" for a
            # run that is about to rewrite the file.
            if before == after:
                changed += 1
            print(f"  {label} run {run}: status {cols[si]} resolved by this "
                  f"rescore, cleared")
            cols[si] = ""
        cols[idx["hits"]], cols[idx["other"]], cols[idx["bugs"]] = after
        out.append("\t".join(cols))

    if check:
        print(f"{changed} row(s) would change")
        return 0
    # Temp file in the SAME directory, then os.replace: the rename is atomic on
    # both platforms this runs on, and same-directory is what keeps it on one
    # filesystem. A direct write leaves a window in which the file on disk is
    # half the old evidence and half the new -- and this file is the derived
    # cache for 40 measured runs, several of whose transcripts are already gone.
    fd, tmp = tempfile.mkstemp(dir=str(RESULTS.parent), prefix=RESULTS.name,
                               suffix=".part")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write("\n".join(out) + "\n")
            # os.replace covers a crash mid-write; only fsync covers a power
            # loss, which can otherwise make the RENAME durable while the bytes
            # behind it are not -- leaving the evidence short or empty.
            fh.flush()
            os.fsync(fh.fileno())
        # mkstemp creates owner-only, and os.replace carries the temp file's
        # mode onto the destination -- so without this the committed evidence
        # silently goes 0644 -> 0600 on every rescore. Git tracks only the exec
        # bit, so nothing in the diff would ever show it.
        shutil.copymode(RESULTS, tmp)
        os.replace(tmp, RESULTS)
    except BaseException:
        # Including KeyboardInterrupt: a ^C between mkstemp and replace would
        # otherwise leave a stray .part beside the evidence it did not touch.
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print(f"rewrote {RESULTS.name}: {changed} row(s) changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
