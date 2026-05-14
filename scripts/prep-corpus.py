#!/usr/bin/env python3
"""Download a HuggingFace dataset and extract its text into a flat corpus file
for use with nyann-bench's `corpus` workload type.

Each dataset has a known schema; this script extracts the relevant text fields
and writes them as plain text separated by newlines.

Usage:
    python prep-corpus.py --dataset lmsys/lmsys-chat-1m --output /mnt/lustre/.../lmsys-chat-1m.txt
    python prep-corpus.py --dataset bigcode/starcoderdata --output /mnt/lustre/.../starcoderdata.txt
    python prep-corpus.py --dataset AI-MO/aimo-validation-aime --output /mnt/lustre/.../aimo-aime.txt

For unknown datasets, pass --fields to specify which columns to extract:
    python prep-corpus.py --dataset my-org/my-data --fields text,summary --output out.txt
"""
import argparse
import os
import sys

# Known dataset schemas: mapping from HF dataset name to extraction config.
# Each entry specifies the split, optional subset, and a function that takes
# a row dict and returns the text to emit (or None to skip).
KNOWN_DATASETS = {
    "lmsys/lmsys-chat-1m": {
        "split": "train",
        "extract": lambda row: "\n".join(
            turn["content"]
            for turn in row.get("conversation", [])
            if turn.get("content")
        ) or None,
    },
    "bigcode/starcoderdata": {
        "split": "train",
        "extract": lambda row: row.get("content"),
    },
    "AI-MO/aimo-validation-aime": {
        "split": "train",
        "extract": lambda row: "\n".join(
            filter(None, [row.get("problem", ""), row.get("solution", "")])
        ) or None,
    },
}

# Friendly short names that map to HF dataset paths
ALIASES = {
    "lmsys-chat-1m": "lmsys/lmsys-chat-1m",
    "chat": "lmsys/lmsys-chat-1m",
    "starcoderdata": "bigcode/starcoderdata",
    "coding": "bigcode/starcoderdata",
    "aimo-aime": "AI-MO/aimo-validation-aime",
    "math": "AI-MO/aimo-validation-aime",
}


def resolve_dataset(name: str) -> str:
    return ALIASES.get(name, name)


def extract_with_fields(row: dict, fields: list[str]) -> str | None:
    parts = [str(row[f]) for f in fields if f in row and row[f]]
    return "\n".join(parts) if parts else None


def main():
    parser = argparse.ArgumentParser(description="Convert HF datasets to flat corpus text for nyann-bench")
    parser.add_argument("--dataset", required=True, help="HuggingFace dataset name or alias (e.g. lmsys-chat-1m)")
    parser.add_argument("--output", required=True, help="Output .txt file path")
    parser.add_argument("--fields", default="", help="Comma-separated field names to extract (for unknown datasets)")
    parser.add_argument("--subset", default="", help="Dataset subset/config name (e.g. 'python' for starcoderdata)")
    parser.add_argument("--split", default="", help="Dataset split (default: train)")
    parser.add_argument("--max-rows", type=int, default=0, help="Max rows to process (0 = all)")
    parser.add_argument("--max-size-mb", type=int, default=500, help="Stop after output exceeds this size in MB (0 = unlimited)")
    parser.add_argument("--hf-token", default="", help="HuggingFace token (or set HF_TOKEN env var)")
    args = parser.parse_args()

    try:
        from datasets import load_dataset
    except ImportError:
        print("ERROR: 'datasets' package not installed. Run: pip install datasets", file=sys.stderr)
        sys.exit(1)

    dataset_name = resolve_dataset(args.dataset)
    print(f"Dataset: {dataset_name}")

    config = KNOWN_DATASETS.get(dataset_name, {})
    split = args.split or config.get("split", "train")
    subset = args.subset or config.get("subset", None)
    extract_fn = config.get("extract")

    if not extract_fn:
        if args.fields:
            fields = [f.strip() for f in args.fields.split(",")]
            extract_fn = lambda row: extract_with_fields(row, fields)
            print(f"Using custom fields: {fields}")
        else:
            print(f"ERROR: Unknown dataset '{dataset_name}' and no --fields specified.", file=sys.stderr)
            print(f"Known datasets: {', '.join(sorted(KNOWN_DATASETS))}", file=sys.stderr)
            print(f"Aliases: {', '.join(sorted(ALIASES))}", file=sys.stderr)
            sys.exit(1)

    token = args.hf_token or os.environ.get("HF_TOKEN")
    load_kwargs = {"split": split, "streaming": True}
    if subset:
        load_kwargs["name"] = subset
    if token:
        load_kwargs["token"] = token

    print(f"Loading {dataset_name} (split={split}, subset={subset or 'default'})...")
    ds = load_dataset(dataset_name, **load_kwargs)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    max_bytes = args.max_size_mb * 1024 * 1024 if args.max_size_mb else 0
    total_bytes = 0
    total_rows = 0

    done = False
    with open(args.output, "w") as f:
        for i, row in enumerate(ds):
            if args.max_rows and i >= args.max_rows:
                print(f"Reached --max-rows={args.max_rows}")
                done = True
                break

            text = extract_fn(row)
            if text:
                f.write(text)
                f.write("\n")
                total_bytes += len(text) + 1
                total_rows += 1

            if max_bytes and total_bytes >= max_bytes:
                print(f"Reached --max-size-mb={args.max_size_mb}")
                done = True
                break

            if total_rows % 10000 == 0 and total_rows > 0:
                print(f"  {total_rows} rows, {total_bytes / 1024 / 1024:.1f} MB...", flush=True)

    print(f"Done: {total_rows} rows, {total_bytes / 1024 / 1024:.1f} MB -> {args.output}", flush=True)
    if done:
        os._exit(0)


if __name__ == "__main__":
    main()
