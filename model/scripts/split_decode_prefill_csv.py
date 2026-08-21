#!/usr/bin/env python3
"""Split each trace CSV into Prefill and Decode CSVs."""

from __future__ import annotations

import csv
import sys
from pathlib import Path


def split_one(input_path: Path, output_dir: Path) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = input_path.stem
    prefill_path = output_dir / f"{stem}_Prefill.csv"
    decode_path = output_dir / f"{stem}_Decode.csv"

    with input_path.open(newline="") as src:
        reader = csv.DictReader(src)
        if reader.fieldnames is None:
            raise ValueError(f"{input_path}: missing CSV header")
        with prefill_path.open("w", newline="") as prefill_fp, decode_path.open("w", newline="") as decode_fp:
            prefill_writer = csv.DictWriter(prefill_fp, fieldnames=reader.fieldnames)
            decode_writer = csv.DictWriter(decode_fp, fieldnames=reader.fieldnames)
            prefill_writer.writeheader()
            decode_writer.writeheader()
            for row in reader:
                phase = row["phase"]
                if phase.endswith("decode_step"):
                    row["phase"] = "decode"
                    decode_writer.writerow(row)
                else:
                    row["phase"] = "prefill"
                    prefill_writer.writerow(row)

    return [prefill_path, decode_path]


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: split_decode_prefill_csv.py OUTPUT_DIR INPUT.csv [INPUT.csv ...]", file=sys.stderr)
        return 2
    output_dir = Path(argv[1])
    for raw_path in argv[2:]:
        for path in split_one(Path(raw_path), output_dir):
            print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
