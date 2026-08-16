#!/usr/bin/env python3
"""Review a git diff with the local LM Studio model (experimental).

Usage:
  scripts/local_review.py                 # review uncommitted changes (git diff HEAD)
  scripts/local_review.py HEAD~1..HEAD    # review a commit range
  scripts/local_review.py main...my-branch

Streams the model's review to stdout. This is an EXPERIMENT alongside the
canonical gates — it does not stamp the code-review-gate hook; /auto-review
or /code-review still owns the commit gate.
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

SERVER = "http://localhost:1234/v1/chat/completions"
MODEL = os.environ.get("LOCAL_REVIEW_MODEL", "qwen3.8-27b-mlx-textonly@6bit")
# ~16 tok/s generation locally; keep the prompt bounded so prompt processing
# doesn't dominate. 120k chars ≈ 30k tokens ≈ a couple of minutes of prefill.
MAX_DIFF_CHARS = 120_000

SYSTEM_PROMPT = """You are a senior Swift/SwiftUI code reviewer. Review the \
diff for CORRECTNESS BUGS: logic errors, off-by-ones, force-unwraps that can \
trap, race conditions, retain cycles, wrong API usage, broken edge cases \
(empty collections, boundary values, nil). Ignore style, naming, and \
formatting.

For each finding output:
- **file:line** — one-sentence defect statement, then the concrete failure \
scenario (inputs/state -> wrong outcome).

Rank most severe first. If the diff has no correctness issues, say exactly \
"No findings." Do not invent findings to seem thorough."""


def get_diff(args: list[str]) -> str:
    if len(args) == 2 and args[0] == "--diff-file":
        with open(args[1], encoding="utf-8") as f:
            return f.read()
    cmd = ["git", "diff"] + (args if args else ["HEAD"])
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        no_head = (
            not args
            and subprocess.run(
                ["git", "rev-parse", "--verify", "HEAD"], capture_output=True
            ).returncode
            != 0
        )
        if not no_head:
            sys.exit(f"git diff failed: {out.stderr.strip()}")
        diff = ""  # repo has no commits yet; everything is untracked
    else:
        diff = out.stdout
    if not args:
        # `git diff` omits untracked files; include them as new-file diffs so
        # a brand-new file isn't silently excluded from its own review.
        ls = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True,
            text=True,
        )
        if ls.returncode != 0:
            sys.exit(f"git ls-files failed: {ls.stderr.strip()}")
        for path in ls.stdout.splitlines():
            nd = subprocess.run(
                ["git", "diff", "--no-index", "--", "/dev/null", path],
                capture_output=True,
                text=True,
            )
            # 0 = identical (empty file); 1 with a patch = differs. Anything
            # else — including status 1 with no patch, which git also uses
            # for access errors — means the scope is incomplete: fail closed.
            if nd.returncode == 0:
                continue
            if nd.returncode == 1 and nd.stdout:
                diff += nd.stdout
                continue
            sys.exit(
                f"could not include untracked file {path!r} in the review "
                f"scope: {nd.stderr.strip() or 'no diff produced'}"
            )
    return diff


def main() -> None:
    diff = get_diff(sys.argv[1:])
    if not diff.strip():
        sys.exit("Diff is empty — nothing to review.")
    if len(diff) > MAX_DIFF_CHARS:
        print(
            f"⚠️  Diff is {len(diff)} chars; truncating to {MAX_DIFF_CHARS}. "
            "Review a narrower range for full coverage.",
            file=sys.stderr,
        )
        diff = diff[:MAX_DIFF_CHARS]

    # off = prefill an empty think block (verified: skips thinking entirely).
    # low = the model's own low-effort template instruction, injected here
    #       because LM Studio doesn't forward template variables.
    thinking = os.environ.get("LOCAL_REVIEW_THINKING", "full")
    system = SYSTEM_PROMPT
    if thinking == "low":
        system = (
            "Reasoning effort is set to low. Keep your thinking brief and "
            "focused, moving directly to the conclusion without unnecessary "
            "elaboration.\n\n" + system
        )
    messages = [
        {"role": "system", "content": system},
        # Six-backtick fence: a three-backtick fence closes early when the
        # diff itself contains fenced code blocks.
        {"role": "user", "content": f"Review this diff:\n\n``````diff\n{diff}\n``````"},
    ]
    if thinking == "off":
        # Split literal: a contiguous think-tag in this source makes any diff
        # of this file unreviewable — the server's reasoning parser strips the
        # tag from the prompt and the reviewing model spirals on the gap.
        tag = "think"
        messages.append(
            {"role": "assistant", "content": f"<{tag}>\n\n</{tag}>\n\n"}
        )

    body = json.dumps(
        {
            "model": MODEL,
            "messages": messages,
            "stream": True,
            # Qwen3-Coder recommended sampling; unset params let the model
            # loop degenerately (observed: 200+ fabricated template findings).
            "temperature": 0.7,
            "top_p": 0.8,
            "top_k": 20,
            "repetition_penalty": 1.05,
            # Reasoning models spend this budget on thinking first — override
            # upward for them or the visible review gets truncated to nothing.
            "max_tokens": int(os.environ.get("LOCAL_REVIEW_MAX_TOKENS", "12000")),
            "stream_options": {"include_usage": True},
        }
    ).encode()

    req = urllib.request.Request(
        SERVER, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        resp = urllib.request.urlopen(req, timeout=900)
    except urllib.error.HTTPError as e:
        # HTTPError subclasses OSError: without this arm a 400/404 (bad model
        # name, bad params) would be misreported as "server not running".
        body = e.read().decode(errors="replace")[:500]
        sys.exit(f"Server rejected the request (HTTP {e.code}): {body}")
    except OSError as e:
        sys.exit(
            f"Can't reach {SERVER} ({e}). Start the server: "
            "~/.lmstudio/bin/lms server start"
        )

    import time

    t_start = time.monotonic()
    t_first_content = None
    reasoning_count = 0
    usage = None
    try:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[len("data: "):])
            if "error" in chunk:
                sys.exit(f"\nServer error: {chunk['error']}")
            if chunk.get("usage"):
                usage = chunk["usage"]
            if not chunk.get("choices"):
                continue  # LM Studio emits stats/keepalive events without choices
            delta = chunk["choices"][0].get("delta", {})
            # Chain-of-thought streams in a separate field; show progress, not text.
            if delta.get("reasoning_content"):
                reasoning_count += 1
                if reasoning_count % 50 == 0:
                    print(f"  …thinking ({reasoning_count} chunks)", file=sys.stderr)
            text = delta.get("content")
            if text:
                if t_first_content is None:
                    t_first_content = time.monotonic()
                print(text, end="", flush=True)
    except OSError as e:
        sys.exit(f"\nStream died mid-response ({e}); output above is incomplete.")
    print()

    if t_first_content is None:
        sys.exit(
            "Model produced no visible review — the thinking phase likely "
            "consumed the whole token budget. Raise LOCAL_REVIEW_MAX_TOKENS "
            "or use a less thinking-hungry model."
        )

    stats_path = os.environ.get("LOCAL_REVIEW_STATS")
    if stats_path:
        t_end = time.monotonic()
        with open(stats_path, "w") as f:
            json.dump(
                {
                    "model": MODEL,
                    "wall_seconds": round(t_end - t_start, 1),
                    "seconds_to_first_answer_token": (
                        round(t_first_content - t_start, 1) if t_first_content else None
                    ),
                    "usage": usage,
                },
                f,
            )


if __name__ == "__main__":
    main()
