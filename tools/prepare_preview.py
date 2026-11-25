#!/usr/bin/env python3
"""Stage the desktop or OpenXR development preview."""
import argparse
import shutil
from pathlib import Path

from prepare_native_import import register_extension


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xr", action="store_true", help="Stage the tracked hammer OpenXR fixture.")
    parser.add_argument("--native", action="store_true", help="Stage the larger XR billet and built native extension.")
    args = parser.parse_args()
    if args.native and not args.xr:
        parser.error("--native requires --xr")
    xr = args.xr
    root = Path(__file__).resolve().parent.parent
    names = ("libblacksmith_native.so", "blacksmith_native.dll")
    libraries = [root / "native/bin" / name for name in names]
    libraries = [path for path in libraries if path.is_file()]
    if args.native and not libraries:
        parser.error("Build the native extension before staging the larger XR preview.")
    folder = "xr-preview-native" if args.native else ("xr-preview" if xr else "preview")
    target = root / ".build" / folder
    target.mkdir(parents=True, exist_ok=True)
    # Copy an explicit allow-list: no native extension, generated cache, credentials
    # or developer files are needed to run the reference solver's small fixture.
    for name in ("src/sim", "src/game", "src/vr", "data/materials", "data/sim", "data/preview", "scenes", "shaders"):
        shutil.copytree(root / name, target / name, dirs_exist_ok=True)
    for name in ("project.godot", "icon.svg"):
        shutil.copy2(root / name, target / name)
    shutil.copytree(root / "assets/forge_room", target / "assets/forge_room", dirs_exist_ok=True)
    if xr:
        project = target / "project.godot"
        config = project.read_text()
        config = config.replace("res://scenes/billet_preview.tscn", "res://scenes/tracked_hammer_preview.tscn")
        config += ("\n[xr]\n\nopenxr/enabled=true\n"
                   "openxr/extensions/hand_tracking=true\n"
                   "openxr/extensions/hand_tracking_unobstructed_data_source=true\n"
                   "openxr/extensions/hand_tracking_controller_data_source=true\n"
                   "openxr/extensions/render_model=true\n"
                   "shaders/enabled=true\n")
        if args.native:
            config += "\n[blacksmith_preview]\n\nnative_solver=true\n"
        project.write_text(config)
    if args.native:
        (target / "native/bin").mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "native/blacksmith.gdextension", target / "native")
        for library in libraries:
            shutil.copy2(library, target / "native/bin")
        register_extension(target, "res://native/blacksmith.gdextension")
    print(f"Preview ready: {target / 'project.godot'}")
    print("Open that project in Godot 4.7+ Standard and press F5.")
    if not args.native:
        print("This small fixture uses GDScript; no native build is required.")


if __name__ == "__main__":
    main()
