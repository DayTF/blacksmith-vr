#!/usr/bin/env python3
"""Prepare Godot's generated extension registry before a cold editor import.

Godot 4.7 can run deferred extension documentation after editor cleanup when a
class is first discovered during import: godotengine/godot#111048 and #123658.
Loading the built extension at startup avoids that discovery/cleanup race.
"""

import argparse
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    project = parser.parse_args().project.resolve()
    manifest = "res://native/blacksmith.gdextension"
    names = {"linux": "libblacksmith_native.so", "win32": "blacksmith_native.dll"}
    name = names.get(sys.platform)
    if name is None:
        parser.error("Native library paths are configured for Linux and Windows only.")
    if not (project / "native/blacksmith.gdextension").is_file():
        parser.error("Native extension manifest is missing.")
    if not (project / "native/bin" / name).is_file():
        parser.error("Build the native extension before preparing the editor import.")
    registry = project / ".godot/extension_list.cfg"
    entries = registry.read_text().splitlines() if registry.exists() else []
    entries = sorted(set(entry for entry in entries if entry.strip()) | {manifest})
    registry.parent.mkdir(parents=True, exist_ok=True)
    temporary = registry.with_suffix(".cfg.tmp")
    temporary.write_text("\n".join(entries) + "\n")
    temporary.replace(registry)
    print("Prepared native startup registry:", registry)


if __name__ == "__main__":
    main()
