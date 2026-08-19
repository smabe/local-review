#!/usr/bin/env python3
"""Live view of the context-tier bench: every step, its state, and its result.

  python3 bench/watch_ctx_tiers.py          # live, redraws every 3 s
  python3 bench/watch_ctx_tiers.py --once   # one static snapshot

A step is one review.sh run. Its state is derived, not reported: the runners
open a log file when a run starts and append a TSV row when it finishes, so a
log with no row is a step in flight. That is the only way to see the step that
is running right now -- a results file alone shows nothing until it is over.

Read-only and cheap on purpose: this watches a benchmark whose numbers include
latency, so it must not compete with it for the machine.
"""
import os
import pathlib
import sys
import time

BENCH = pathlib.Path(__file__).resolve().parent
LOGS = BENCH / "logs"
ARMS = [
    ("qwen38-nothink-ctx48k", 49152),
    ("qwen38-nothink-ctx64k", 65536),
    ("qwen38-nothink-ctx96k", 98304),
]
CASES = ["offbyone", "swallow", "boolean", "leak", "clean"]
RUNS = 2
DEFECT_CASES = {"offbyone", "swallow", "boolean", "leak"}

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
GREEN, RED, YELLOW, BLUE, GREY = (
    "\033[32m", "\033[31m", "\033[33m", "\033[36m", "\033[90m")


def read_tsv(path):
    if not path.exists():
        return []
    lines = path.read_text().splitlines()
    if not lines:
        return []
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:] if l.strip()]


def started_at(name):
    """When a step's log was last (re)started, or None if it has not started.

    mtime, not birthtime: the runners truncate an existing log in place on a
    re-run, which updates mtime but preserves birthtime -- a birthtime-based
    timer would count a second pass's steps from the FIRST pass's start."""
    p = LOGS / name
    if not p.exists():
        return None
    return p.stat().st_mtime


def hms(secs):
    secs = int(secs)
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"


def peak_wired_gb(label):
    f = LOGS / f"{label}-wired.txt"
    if not f.exists():
        return None
    best = 0
    for line in f.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].strip().isdigit():
            best = max(best, int(parts[1]))
    return best / 1073741824 if best else None


def small_verdict(row):
    """What the run means, in the bench's own terms."""
    exit_code, case = row["exit"], row["case"]
    if exit_code == "124":
        return RED, "TIMED OUT"
    if exit_code == "3":
        return RED, "untrusted verdict"
    if exit_code == "1":
        return RED, "error"
    if case == "clean":
        return (GREEN, "clean, as expected") if exit_code == "0" \
            else (RED, f"FABRICATED {row['nfind']}")
    if row["found"] == "1":
        return GREEN, "caught"
    if row["found_any"] == "1":
        return YELLOW, "quoted, not trusted"
    return RED, "MISSED"


def big_verdict(row):
    if row["exit"] == "124":
        return RED, "TIMED OUT"
    if row["exit"] in ("1", "3"):
        return RED, "untrusted verdict"
    hits, other = int(row["hits"]), int(row["other"])
    if hits == 0:
        return RED, "FALSE CLEAN" if row["exit"] == "0" else "0 known bugs"
    colour = GREEN if other == 0 else YELLOW
    tail = f", {other} unmatched" if other else ""
    return colour, f"{hits}/6 known bugs{tail}"


def render(started):
    small = read_tsv(BENCH / "results.tsv")
    big = read_tsv(BENCH / "results-bigdiff.tsv")
    now = time.time()
    out = []
    total_steps = len(ARMS) * (len(CASES) * RUNS + RUNS)
    done_steps = 0

    for arm_no, (label, ctx) in enumerate(ARMS, 1):
        rows = {(r["case"], r["run"]): r for r in small if r["label"] == label}
        brows = {r["run"]: r for r in big if r["label"] == label}
        steps = []

        for run in range(1, RUNS + 1):
            for case in CASES:
                key = (case, str(run))
                logname = f"{label}-{case}-r{run}.txt"
                if key in rows:
                    r = rows[key]
                    colour, text = small_verdict(r)
                    steps.append(("done", f"small  {case:<9} r{run}",
                                  f"exit {r['exit']}  {r['secs']:>4}s", colour, text))
                else:
                    t0 = started_at(logname)
                    steps.append(("running" if t0 else "pending",
                                  f"small  {case:<9} r{run}",
                                  hms(now - t0) if t0 else "", BLUE, ""))

        for run in range(1, RUNS + 1):
            logname = f"{label}-bigdiff-r{run}.txt"
            if str(run) in brows:
                r = brows[str(run)]
                colour, text = big_verdict(r)
                steps.append(("done", f"bigdiff{'':<10} r{run}",
                              f"exit {r['exit']}  {r['secs']:>4}s", colour, text))
            else:
                t0 = started_at(logname)
                steps.append(("running" if t0 else "pending",
                              f"bigdiff{'':<10} r{run}",
                              hms(now - t0) if t0 else "", BLUE, ""))

        n_done = sum(1 for s in steps if s[0] == "done")
        done_steps += n_done
        running = any(s[0] == "running" for s in steps)
        if n_done == len(steps):
            head_state, head_colour = "done", GREEN
        elif running or n_done:
            head_state, head_colour = "running", BLUE
        else:
            head_state, head_colour = "pending", GREY

        peak = peak_wired_gb(label)
        peak_txt = f"peak wired {peak:.1f} GB" if peak else ""
        out.append(f"{BOLD}arm {arm_no}/3{RESET}  ctx {ctx:<6} {label:<24}"
                   f"{head_colour}{head_state:<8}{RESET} {DIM}{n_done}/{len(steps)}"
                   f"  {peak_txt}{RESET}")

        for state, name, timing, colour, text in steps:
            if state == "done":
                out.append(f"   {GREEN}v{RESET} {name}  {DIM}{timing}{RESET}  {colour}{text}{RESET}")
            elif state == "running":
                out.append(f"   {BLUE}>{RESET} {name}  {BLUE}running {timing}{RESET}")
            else:
                out.append(f"   {GREY}. {name}{RESET}")
        out.append("")

    filled = int(30 * done_steps / total_steps)
    bar = "#" * filled + "-" * (30 - filled)
    header = (f"{BOLD}local-review - context-tier bench{RESET}   "
              f"[{bar}] {done_steps}/{total_steps} steps   "
              f"elapsed {hms(now - started)}")
    return header + "\n\n" + "\n".join(out)


def main():
    once = "--once" in sys.argv
    started = time.time()
    # Anchor elapsed time on the oldest arm log, so a watcher started midway
    # through still reports the bench's elapsed time rather than its own.
    # Case/bigdiff logs only: the bare prefix also matches -wired.txt,
    # -server.txt and -models.json.bak, which belong to arm infrastructure
    # and can long predate the first actual review step.
    stamps = [started_at(p.name) for p in LOGS.glob("qwen38-nothink-ctx*-r*.txt")] if LOGS.exists() else []
    stamps = [s for s in stamps if s]
    if stamps:
        started = min(stamps)

    if once:
        print(render(started))
        return 0
    try:
        while True:
            sys.stdout.write("\033[H\033[J" + render(started) + "\n")
            sys.stdout.flush()
            time.sleep(3)
    except KeyboardInterrupt:
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
