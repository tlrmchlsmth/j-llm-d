#!/usr/bin/env python3
"""Validate corpus files used by nyann-bench.

Samples random windows (matching nyann-bench's sliding-window behavior)
and checks for common issues: truncation, low diversity, null bytes,
repetitive content, or dominance by a single language/pattern.

Uses seek-based sampling to avoid loading multi-GB files into memory.

Usage:
    python validate-corpus.py /mnt/lustre/imarkov/corpus/starcoderdata.txt
    python validate-corpus.py /mnt/lustre/imarkov/corpus/*.txt
    python validate-corpus.py --compare /mnt/lustre/imarkov/corpus/{sharegpt,lmsys-chat-1m,starcoderdata}.txt
"""
import argparse
import math
import os
import random
import sys
from collections import Counter


def read_window(f, file_size: int, offset: int, window_bytes: int) -> str:
    """Read a window from file at byte offset, wrapping if needed."""
    f.seek(offset)
    if offset + window_bytes <= file_size:
        return f.read(window_bytes)
    # Wrap around
    tail = f.read(file_size - offset)
    f.seek(0)
    head = f.read(window_bytes - len(tail))
    return tail + head


def sample_windows(f, file_size: int, window_bytes: int = 2000, n: int = 20) -> list[str]:
    """Sample n random windows by seeking, same as nyann-bench."""
    if file_size < window_bytes:
        f.seek(0)
        return [f.read()]
    windows = []
    for _ in range(n):
        offset = random.randint(0, file_size - 1)
        windows.append(read_window(f, file_size, offset, window_bytes))
    return windows


def read_chunk(f, offset: int, size: int) -> str:
    """Read a chunk from file at a byte offset."""
    f.seek(offset)
    return f.read(size)


def entropy(text: str) -> float:
    """Shannon entropy in bits per character."""
    if not text:
        return 0.0
    counts = Counter(text)
    total = len(text)
    return -sum((c / total) * math.log2(c / total) for c in counts.values())


def count_newlines_sampled(f, file_size: int, sample_size: int = 10_000_000) -> tuple[int, float]:
    """Estimate newline count and avg line length by sampling chunks."""
    if file_size <= sample_size:
        f.seek(0)
        text = f.read()
        nl = text.count("\n")
        return nl, len(text) / max(nl, 1)

    # Sample from start, middle, end
    chunk_size = sample_size // 3
    chunks = []
    for offset in [0, file_size // 2, file_size - chunk_size]:
        chunks.append(read_chunk(f, max(0, offset), chunk_size))

    sampled = "".join(chunks)
    nl_in_sample = sampled.count("\n")
    # Extrapolate
    ratio = file_size / len(sampled)
    est_newlines = int(nl_in_sample * ratio)
    avg_line = file_size / max(est_newlines, 1)
    return est_newlines, avg_line


def analyze_file(path: str, window_bytes: int = 2000, n_samples: int = 20):
    """Analyze a single corpus file using seek-based sampling (low memory)."""
    size_bytes = os.path.getsize(path)
    size_mb = size_bytes / (1024 * 1024)
    print(f"\n{'='*70}")
    print(f"File: {path}")
    print(f"Size: {size_mb:.1f} MB ({size_bytes:,} bytes)")

    with open(path, "r", errors="replace") as f:
        # Newline estimate
        est_newlines, avg_line_len = count_newlines_sampled(f, size_bytes)
        print(f"Lines (est): ~{est_newlines:,} (avg ~{avg_line_len:.0f} chars/line)")

        # Entropy from a 500K sample at the start
        start_chunk = read_chunk(f, 0, 500_000)
        ent_start = entropy(start_chunk)

        # Entropy from a 500K sample at a random middle offset
        mid_offset = random.randint(size_bytes // 4, 3 * size_bytes // 4)
        mid_chunk = read_chunk(f, mid_offset, 500_000)
        ent_mid = entropy(mid_chunk)

        print(f"Entropy: start={ent_start:.2f} mid={ent_mid:.2f} bits/char")

        # Null byte check (sample 10MB spread across file)
        null_count = 0
        for probe_offset in range(0, size_bytes, size_bytes // 10):
            probe = read_chunk(f, probe_offset, 100_000)
            null_count += probe.count("\0")
        if null_count > 0:
            print(f"WARNING: ~{null_count:,} null bytes found in sampled regions!")

        # Character class breakdown from start + mid
        combined = start_chunk + mid_chunk
        total = len(combined)
        alpha = sum(1 for c in combined if c.isalpha())
        digit = sum(1 for c in combined if c.isdigit())
        space = sum(1 for c in combined if c == " ")
        newline = sum(1 for c in combined if c == "\n")
        punct = sum(1 for c in combined if not c.isalnum() and not c.isspace())
        print(f"Char classes: alpha={alpha/total:.1%} digit={digit/total:.1%} "
              f"space={space/total:.1%} newline={newline/total:.1%} punct={punct/total:.1%}")

        # Sample windows (the actual thing nyann-bench sends)
        print(f"\n--- {n_samples} random windows ({window_bytes} chars each) ---")
        windows = sample_windows(f, size_bytes, window_bytes, n_samples)

    window_entropies = []
    unique_trigrams_per_window = []
    for w in windows:
        we = entropy(w)
        window_entropies.append(we)
        trigrams = set(w[j: j + 3] for j in range(len(w) - 2))
        unique_trigrams_per_window.append(len(trigrams))

    avg_ent = sum(window_entropies) / len(window_entropies)
    min_ent = min(window_entropies)
    max_ent = max(window_entropies)
    print(f"Window entropy: avg={avg_ent:.2f} min={min_ent:.2f} max={max_ent:.2f} bits/char")

    avg_tri = sum(unique_trigrams_per_window) / len(unique_trigrams_per_window)
    min_tri = min(unique_trigrams_per_window)
    print(f"Unique trigrams/window: avg={avg_tri:.0f} min={min_tri} (low = repetitive)")

    # Check for long repetitive runs
    max_repeat = 0
    for w in windows:
        for run_len in [50, 100, 200]:
            pattern = w[:run_len]
            if pattern * 2 in w:
                max_repeat = max(max_repeat, run_len)
    if max_repeat > 0:
        print(f"WARNING: Found repeated patterns of length {max_repeat}+ in sampled windows")

    # Show 3 sample windows (truncated)
    print(f"\n--- Sample window previews (first 200 chars) ---")
    show_indices = [0, len(windows) // 2, len(windows) - 1]
    for idx in show_indices:
        w = windows[idx]
        preview = w[:200].replace("\n", "\\n")
        print(f"  [{idx}] {preview}...")

    # Content diversity: first line of each of 10 windows
    print(f"\n--- Content diversity (10 windows, first 80 chars) ---")
    for i in range(min(10, len(windows))):
        first_line = windows[i].split("\n")[0][:80]
        print(f"  [{i:2d}] {first_line}")

    return {
        "path": path,
        "size_mb": size_mb,
        "entropy_start": ent_start,
        "entropy_mid": ent_mid,
        "avg_window_entropy": avg_ent,
        "min_window_entropy": min_ent,
        "avg_line_len": avg_line_len,
        "null_bytes": null_count,
    }


def compare_files(results: list[dict]):
    """Print comparison table."""
    if len(results) < 2:
        return
    print(f"\n{'='*70}")
    print("COMPARISON")
    print(f"{'='*70}")
    print(f"{'File':<25} {'Size MB':>8} {'EntStart':>8} {'EntMid':>8} {'WinEnt':>8} {'MinWinE':>8} {'AvgLine':>8}")
    print("-" * 75)
    for r in results:
        name = os.path.basename(r["path"])
        print(f"{name:<25} {r['size_mb']:>7.1f} {r['entropy_start']:>8.2f} "
              f"{r['entropy_mid']:>8.2f} {r['avg_window_entropy']:>8.2f} "
              f"{r['min_window_entropy']:>8.2f} {r['avg_line_len']:>8.0f}")

    # Flag potential issues
    print("\n--- Potential issues ---")
    for r in results:
        name = os.path.basename(r["path"])
        issues = []
        if r["size_mb"] < 100:
            issues.append(f"small file ({r['size_mb']:.0f} MB)")
        if r["null_bytes"] > 0:
            issues.append(f"~{r['null_bytes']} null bytes")
        if r["min_window_entropy"] < 2.0:
            issues.append(f"very low entropy window ({r['min_window_entropy']:.2f})")
        if r["avg_line_len"] < 20:
            issues.append(f"very short lines (avg {r['avg_line_len']:.0f} chars)")
        if abs(r["entropy_start"] - r["entropy_mid"]) > 1.0:
            issues.append(f"entropy varies a lot across file (start={r['entropy_start']:.2f} mid={r['entropy_mid']:.2f})")
        if issues:
            print(f"  {name}: {'; '.join(issues)}")
        else:
            print(f"  {name}: OK")


def main():
    parser = argparse.ArgumentParser(description="Validate nyann-bench corpus files")
    parser.add_argument("files", nargs="+", help="Corpus .txt files to validate")
    parser.add_argument("--window", type=int, default=2000, help="Window size in chars (default: 2000, matching ISL=500)")
    parser.add_argument("--samples", type=int, default=20, help="Number of random windows to sample")
    parser.add_argument("--compare", action="store_true", help="Print comparison table at the end")
    parser.add_argument("--seed", type=int, default=42, help="Random seed for reproducibility")
    args = parser.parse_args()

    random.seed(args.seed)

    results = []
    for path in args.files:
        if not os.path.isfile(path):
            print(f"WARNING: {path} not found, skipping", file=sys.stderr)
            continue
        r = analyze_file(path, args.window, args.samples)
        results.append(r)

    if len(results) > 1 or args.compare:
        compare_files(results)


if __name__ == "__main__":
    main()
