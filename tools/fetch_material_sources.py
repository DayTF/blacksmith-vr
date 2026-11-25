#!/usr/bin/env python3
"""Fetch checksum-pinned research files without installing them in the game catalog."""

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path
from os import link
from urllib.request import urlopen


def fetch(entry: dict, output: Path) -> None:
    name = entry["name"]
    if Path(name).name != name or name in {"", ".", ".."}:
        raise ValueError(f"Invalid source filename {name!r}")
    destination = output / name
    expected = entry["sha256"]
    if destination.exists():
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Checksum mismatch for existing file {destination}")
        print(f"Verified {destination}")
        return

    with urlopen(entry["url"], timeout=30) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Checksum mismatch for download {name}")
    with tempfile.TemporaryDirectory(dir=output) as work:
        verified = Path(work) / name
        verified.write_bytes(data)
        # Linking publishes atomically and preserves any file that races the fetch.
        link(verified, destination)
    print(f"Downloaded and verified {destination}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        args.output.mkdir(parents=True, exist_ok=True)
        for entry in manifest["files"]:
            fetch(entry, args.output)
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
