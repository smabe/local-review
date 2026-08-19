#!/usr/bin/env python3
"""Summarize the context-tier arms: detection, fabrication, latency, memory.

Reads bench/results.tsv (small cases), bench/results-bigdiff.tsv, and the
per-arm wired-memory samples in bench/logs/. Prints one table per measurement
so a tier can be compared on each axis independently -- the tiers were never
expected to differ on detection, and lumping latency in with it would hide
whichever one does move.
"""
import pathlib
import statistics
import sys

BENCH = pathlib.Path(__file__).resolve().parent
ARMS = [
    ("qwen38-nothink-ctx48k", 49152),
    ("qwen38-nothink-ctx64k", 65536),
    ("qwen38-nothink-ctx96k", 98304),
]
DEFECT_CASES = ["offbyone", "swallow", "boolean", "leak"]
# Added by the 2026-08-19 header migration. The results files are legitimately
# mixed-width from that commit forward -- the header carries these names and
# the 385 rows written before it do not -- so they are defaulted here rather
# than backfilled into the data. Every OTHER name stays a strict lookup, so a
# genuine schema error still fails loudly instead of reading as an old row.
NEW_COLUMNS = ("status", "date", "sha", "vsurv", "vtotal")


def read_tsv(path):
    lines = path.read_text().splitlines()
    if not lines:
        return []
    head = lines[0].split("\t")
    # The columns a row must carry to be readable: everything the header names
    # except the ones added by the 2026-08-19 migration, which are legitimately
    # absent on the rows written before it.
    required = [name for name in head if name not in NEW_COLUMNS]
    rows = []
    for l in lines[1:]:
        if not l.strip():
            continue
        # zip truncates to the shorter side, so a narrow row maps every name it
        # does have correctly and simply omits the rest.
        row = dict(zip(head, l.split("\t")))
        # A line short of those columns is a kill mid-append, not a row: the
        # runners deliberately leave it in place rather than rewriting evidence
        # (bench/README.md, resume). The threshold is what a READER indexes, not
        # what resume keys on -- a cut that lands after `label`/`run` yields a
        # key and then dies on the first missing column, and this one runs at
        # the end of every arm.
        if any(name not in row for name in required):
            sys.stderr.write(f"{path.name}: dropping a truncated line "
                             f"({len(row)} of {len(required)} field(s)) -- a "
                             f"batch killed mid-append\n")
            continue
        for name in NEW_COLUMNS:
            row.setdefault(name, "")
        rows.append(row)
    return rows


def measurements(rows, label):
    """One label's rows, minus the terminal rows that are not measurements.

    A batch that aborts on infrastructure appends a single row carrying the
    reserved non-numeric token `abort` in `run`, so it is not a dispatchable
    key. Its numeric cells are padded with zeros -- nothing indexes it, and a
    bare int() sweep over a label would otherwise raise -- which is exactly why
    an aggregate that took it at face value would report a run of 0 seconds
    that never happened. Filtering on the token, not on `status`: rows that
    ARE measurements keep their status for the readers to weigh.
    """
    return [r for r in rows if r["label"] == label and r["run"].isdigit()]


def unreached(row):
    """True when the run behind this row never got a verdict out of the model.

    Two signals, and they cover different eras of the corpus. A non-empty
    `status` is the marker the runners write when a run failed for an
    infrastructure reason (SUSPECT, SERVER-DOWN, EMPTY-LOG, ...). `exit == 1`
    is review.sh's own error exit, and it is what makes this work backwards:
    the rows written before the status column existed carry no marker at all,
    so without the exit clause every historical junk run would stay in the
    denominator (the operator hand-excluded 11 of them during the 2026-08-19
    outage -- docs/angle-stale-comment.md -- which is the labour this replaces).

    Exit 3 (untrusted verdict) and 124 (timeout) are deliberately NOT here, and
    the asymmetry with the fabrication column below is the point rather than an
    oversight. Detection asks "did it catch this planted defect", which a run
    that timed out answers: no. Fabrication asks "did it invent a finding on a
    clean diff", which the same run does not answer at all -- there is no
    trustworthy verdict to read a finding count out of. So a 3 or a 124 is a
    real detection miss and an unanswerable fabrication question, while an
    exit 1 or a status marker is neither, because nothing was measured.
    """
    return bool(row.get("status", "")) or row.get("exit", "") == "1"


def peak_wired_gb(label):
    f = BENCH / "logs" / f"{label}-wired.txt"
    if not f.exists():
        return None
    vals = []
    for line in f.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].strip().isdigit():
            vals.append(int(parts[1]))
    return max(vals) / 1073741824 if vals else None


def main():
    small = read_tsv(BENCH / "results.tsv")
    big = read_tsv(BENCH / "results-bigdiff.tsv")

    print("== small cases: detection (catch = planted line quoted AND exit 4) ==")
    print(f"{'arm':24} {'ctx':>6} {'catches':>9} {'clean-diff':>12} {'median s':>9} {'range s':>12}")
    for label, ctx in ARMS:
        rows = measurements(small, label)
        if not rows:
            print(f"{label:24} {ctx:>6} {'(no data)':>9}")
            continue
        scored = [r for r in rows if not unreached(r)]
        dropped = len(rows) - len(scored)
        # Say it on the arm's own line. An arm scored over half its rows that
        # prints a bare rate is indistinguishable from one that ran clean, and
        # that silence is what made the manual exclusion necessary.
        note = f"  ({dropped} row(s) excluded: never reached the model)" if dropped else ""

        defects = [r for r in scored if r["case"] in DEFECT_CASES]
        catches = sum(int(r["found"]) for r in defects)
        cleans = [r for r in rows if r["case"] == "clean"]
        scored_cleans = [r for r in cleans if not unreached(r)]
        # A fabrication is a FINDING on a genuinely clean refactor, so count the
        # audit's own validated finding count -- not "exit was not 0". Exit 3
        # (untrusted verdict) and 124 (timeout) mean there is no usable verdict
        # at all, which is a different failure and is reported in its own table
        # below; scoring them here would both invent fabrications that never
        # happened and double-report the same run.
        # ... which requires actually filtering on exit: nfind alone counts a
        # half-emitted block on an exit-3 run as a fabrication.
        fab = sum(1 for r in scored_cleans if r["exit"] == "4")
        unusable = sum(1 for r in scored_cleans if r["exit"] in ("3", "124"))
        secs = sorted(int(r["secs"]) for r in scored)
        if fab:
            clean_txt = f"{fab} fabricated"
        elif unusable:
            clean_txt = f"{unusable} unusable"
        elif not scored_cleans:
            # Every clean run of this arm is excluded, so there is no evidence
            # either way. Saying "passed" here would report a pass for a run
            # that never happened -- the same bug as counting one as a miss.
            clean_txt = f"{len(cleans)} excluded" if cleans else "(no clean)"
        else:
            clean_txt = "passed"
        if not scored:
            print(f"{label:24} {ctx:>6} {'(none)':>9} {clean_txt:>12}{note}")
            continue
        catch_txt = f"{catches}/{len(defects)}" if defects else "(none)"
        print(f"{label:24} {ctx:>6} {catch_txt:>9} {clean_txt:>12} "
              f"{statistics.median(secs):>9.0f} {f'{secs[0]}-{secs[-1]}':>12}{note}")

    print()
    print("== small cases: bad runs (exit 1 / 3 / 124, or an infrastructure marker) ==")
    # This is where a row the table above dropped becomes inspectable. Counting
    # exclusions without ever naming them turns one silence into another: a
    # status-marked run can carry exit 0 and would otherwise appear nowhere.
    any_bad = False
    for label, _ in ARMS:
        for r in measurements(small, label):
            marker = r.get("status", "")
            if marker or r["exit"] in ("1", "3", "124"):
                any_bad = True
                tail = f" [{marker}]" if marker else ""
                print(f"  {label} {r['case']} run {r['run']}: exit {r['exit']} after {r['secs']}s{tail}")
    if not any_bad:
        print("  none")

    print()
    print("== bigdiff (18.3 KB, 6 known bugs since 2026-08-19) ==")
    print(f"{'arm':24} {'run':>4} {'exit':>5} {'secs':>6} {'nfind':>6} {'hits':>5} {'other':>6}  bugs")
    for label, _ in ARMS:
        for r in measurements(big, label):
            print(f"{label:24} {r['run']:>4} {r['exit']:>5} {r['secs']:>6} "
                  f"{r['nfind']:>6} {r['hits']:>5} {r['other']:>6}  {r['bugs']}")

    print()
    print("== peak wired memory (whole arm, 15 s sampling) ==")
    for label, ctx in ARMS:
        gb = peak_wired_gb(label)
        print(f"{label:24} {ctx:>6} {f'{gb:.1f} GB' if gb else '(no data)':>10}")


if __name__ == "__main__":
    sys.exit(main())
