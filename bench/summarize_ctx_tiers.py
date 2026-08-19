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
    rows = []
    for l in lines[1:]:
        if not l.strip():
            continue
        # zip truncates to the shorter side, so a narrow row maps every name it
        # does have correctly and simply omits the rest.
        row = dict(zip(head, l.split("\t")))
        # A line too short to carry a key is a kill mid-append, not a row: the
        # runners deliberately leave it in place rather than rewriting evidence
        # (bench/README.md, resume). Without this every reader below dies on
        # r["run"] -- and this one runs at the end of every arm.
        if "label" not in row or "run" not in row:
            sys.stderr.write(f"{path.name}: dropping a truncated line "
                             f"({len(row)} field(s)) -- a batch killed "
                             f"mid-append\n")
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
        defects = [r for r in rows if r["case"] in DEFECT_CASES]
        catches = sum(int(r["found"]) for r in defects)
        cleans = [r for r in rows if r["case"] == "clean"]
        # A fabrication is a FINDING on a genuinely clean refactor, so count the
        # audit's own validated finding count -- not "exit was not 0". Exit 3
        # (untrusted verdict) and 124 (timeout) mean there is no usable verdict
        # at all, which is a different failure and is reported in its own table
        # below; scoring them here would both invent fabrications that never
        # happened and double-report the same run.
        # ... which requires actually filtering on exit: nfind alone counts a
        # half-emitted block on an exit-3 run as a fabrication.
        fab = sum(1 for r in cleans if r["exit"] == "4")
        unusable = sum(1 for r in cleans if r["exit"] in ("1", "3", "124"))
        secs = sorted(int(r["secs"]) for r in rows)
        if fab:
            clean_txt = f"{fab} fabricated"
        elif unusable:
            clean_txt = f"{unusable} unusable"
        else:
            clean_txt = "passed"
        print(f"{label:24} {ctx:>6} {f'{catches}/{len(defects)}':>9} {clean_txt:>12} "
              f"{statistics.median(secs):>9.0f} {f'{secs[0]}-{secs[-1]}':>12}")

    print()
    print("== small cases: untrusted verdicts and timeouts (exit 3 / 124 / 1) ==")
    any_bad = False
    for label, _ in ARMS:
        for r in measurements(small, label):
            if r["exit"] in ("1", "3", "124"):
                any_bad = True
                print(f"  {label} {r['case']} run {r['run']}: exit {r['exit']} after {r['secs']}s")
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
