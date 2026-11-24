#!/usr/bin/env python3
"""Stage the small GDScript-only desktop preview without a native build toolchain."""
import shutil
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    target = root / ".build" / "preview"
    target.mkdir(parents=True, exist_ok=True)
    # Copy an explicit allow-list: no native extension, generated cache, credentials
    # or developer files are needed to run the reference solver's small fixture.
    for name in ("src/sim", "src/game", "data/materials", "data/sim", "data/preview", "scenes"):
        shutil.copytree(root / name, target / name, dirs_exist_ok=True)
    for name in ("project.godot", "icon.svg"):
        shutil.copy2(root / name, target / name)
    print(f"Preview ready: {target / 'project.godot'}")
    print("Open that project in Godot 4.7+ Standard and press F5.")
    print("This small desktop fixture uses GDScript; no native build is required.")


if __name__ == "__main__":
    main()
