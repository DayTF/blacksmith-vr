#!/usr/bin/env python3
"""Stage the small GDScript-only desktop preview without a native build toolchain."""
import argparse
import shutil
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xr", action="store_true", help="Stage the tracked hammer OpenXR fixture.")
    xr = parser.parse_args().xr
    root = Path(__file__).resolve().parent.parent
    target = root / ".build" / ("xr-preview" if xr else "preview")
    target.mkdir(parents=True, exist_ok=True)
    # Copy an explicit allow-list: no native extension, generated cache, credentials
    # or developer files are needed to run the reference solver's small fixture.
    for name in ("src/sim", "src/game", "src/vr", "data/materials", "data/sim", "data/preview", "scenes", "shaders"):
        shutil.copytree(root / name, target / name, dirs_exist_ok=True)
    for name in ("project.godot", "icon.svg"):
        shutil.copy2(root / name, target / name)
    if xr:
        project = target / "project.godot"
        config = project.read_text()
        config = config.replace("res://scenes/billet_preview.tscn", "res://scenes/tracked_hammer_preview.tscn")
        config += ("\n[xr]\n\nopenxr/enabled=true\n"
                   "openxr/extensions/hand_tracking=true\n"
                   "openxr/extensions/hand_tracking_unobstructed_data_source=true\n"
                   "openxr/extensions/render_model=true\n"
                   "shaders/enabled=true\n")
        project.write_text(config)
    print(f"Preview ready: {target / 'project.godot'}")
    print("Open that project in Godot 4.7+ Standard and press F5.")
    print("This small desktop fixture uses GDScript; no native build is required.")


if __name__ == "__main__":
    main()
