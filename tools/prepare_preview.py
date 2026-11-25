#!/usr/bin/env python3
"""Prepare the Desktop and VR Godot launch folders."""
import argparse
import shutil
from pathlib import Path

from prepare_native_import import register_extension


SHARED_DIRECTORIES = ("src/sim", "src/game", "src/vr", "data/materials", "data/sim",
                      "data/preview", "scenes", "shaders", "assets/forge_room")
MANIFEST = "native/blacksmith.gdextension"


def prepare(root, target, libraries=(), *, xr=False, validation=False):
    target.mkdir(parents=True, exist_ok=True)
    for name in SHARED_DIRECTORIES:
        shutil.copytree(root / name, target / name, dirs_exist_ok=True)
    if validation:
        for name in ("tests", "data/research"):
            shutil.copytree(root / name, target / name, dirs_exist_ok=True)
    shutil.copy2(root / "icon.svg", target)
    config = (root / "project.godot.in").read_text(encoding="utf-8")
    mode = "VR" if xr else "Desktop"
    config = config.replace('config/name="Blacksmith VR"', f'config/name="Blacksmith {mode}"')
    if xr:
        config = config.replace("res://scenes/billet_preview.tscn", "res://scenes/tracked_hammer_preview.tscn")
        config += ("\n[xr]\n\nopenxr/enabled=true\n"
                   "openxr/extensions/hand_tracking=true\n"
                   "openxr/extensions/hand_tracking_unobstructed_data_source=true\n"
                   "openxr/extensions/hand_tracking_controller_data_source=true\n"
                   "openxr/extensions/render_model=true\n"
                   "shaders/enabled=true\n")
        if libraries:
            config += "\n[blacksmith_preview]\n\nnative_solver=true\n"
    (target / "project.godot").write_text(config, encoding="utf-8")
    if libraries:
        (target / "native/bin").mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / MANIFEST, target / MANIFEST)
        for library in libraries:
            shutil.copy2(library, target / "native/bin")
        register_extension(target, "res://" + MANIFEST)
    else:
        (target / MANIFEST).unlink(missing_ok=True)
        registry = target / ".godot/extension_list.cfg"
        if registry.exists():
            entries = [entry for entry in registry.read_text().splitlines()
                       if entry.strip() != "res://" + MANIFEST]
            registry.write_text("".join(entry + "\n" for entry in entries))
    print(f"Ready: {target / 'project.godot'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--desktop", action="store_true", help="Refresh only Desktop.")
    mode.add_argument("--xr", action="store_true", help="Refresh only VR using the reference solver unless --native is supplied.")
    mode.add_argument("--validation-dir", type=Path, help="Stage a temporary full test project outside the repository.")
    parser.add_argument("--native", action="store_true", help="Require a built native solver for VR.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    names = ("libblacksmith_native.so", "blacksmith_native.dll")
    available = [root / "native/bin" / name for name in names if (root / "native/bin" / name).is_file()]
    if args.desktop and args.native:
        parser.error("--native applies to VR")
    if (args.native or args.validation_dir) and not available:
        parser.error("Build the native solver before requesting native staging.")
    if args.validation_dir:
        target = args.validation_dir.resolve()
        if root == target or root in target.parents:
            parser.error("The validation directory must be outside the repository.")
        prepare(root, target, available, validation=True)
        return
    if not args.xr:
        prepare(root, root / "Desktop")
    if not args.desktop:
        libraries = available if args.native or not args.xr else ()
        prepare(root, root / "VR", libraries, xr=True)


if __name__ == "__main__":
    main()
