# Blacksmith VR

A VR blacksmithing simulator with granular, data-driven materials and physical forging.

Try the early desktop preview now. It shows a small live billet under synthetic
hammer strikes: compare hot plastic deformation with cold fracture, replay/pause,
and orbit the view. This is an inspection demo, before tracked VR input or the
full forging loop.

```sh
python3 tools/prepare_preview.py
```

Open `.build/preview/project.godot` in **Godot 4.7+ Standard** and press **F5**.
This stages a GDScript-only, 81-point fixture: no C++ toolchain is needed for the
preview. Re-run the command after source changes. Alternatively, run
`godot --path .build/preview`. The full root project still requires the native
extension build described in [AGENTS.md](AGENTS.md).

- Right mouse drag: orbit. Mouse wheel: zoom.
- Use the temperature dropdown to restart hot (1000 °C) or cold (20 °C).
- Replay restarts the synthetic sequence; Pause/Resume allows inspection.
- The panel reports plastic strain, broken links and the most recent CPU step.
  Red lattice links are broken; the surface mesh does not split at cracks yet.

Temperatures are constant fixture inputs, not a heating/cooling simulation.
Impurities, folding/welding, tracked hammering, naming and inventory are not wired
into this preview. Materials and mechanics are provisional; this is useful visual
feedback for development, not calibrated forging behavior. Both hot and cold billets now remain intact under their own weight
before strikes. The hammer block
illustrates scripted impacts; it is not a tracked or simulated rigid-body tool.

The fixture preserves the solver's 4 substeps × 8 iterations and 1/90 s numerical
step. It runs at most one step per rendered frame: slow rendering slows demo time
without increasing the timestep or building a catch-up queue. Lower development
frame rates are accepted. The 5,000-point benchmark and production 90 Hz / <1 ms
simulation targets remain separate; optimization is deferred behind visual work.

For automated scene verification or an actual rendered capture:

```sh
godot --headless --path .build/preview -- --preview-smoke
godot --headless --path .build/preview -- --preview-smoke --preview-cold
godot --path .build/preview -- --preview-capture=/absolute/path/preview.png
```

Add `--preview-before-strike` to verify/capture the undamaged resting billet.
The normal runs finish after six synthetic strikes and check for finite geometry and a
mechanical response. Captures require a working graphical display and driver.
The preview has been rendered on Windows / RTX 3080 Ti / Vulkan Forward+ and run
headlessly on Linux/WSL. No XR headset or tracked input is validated yet.

Work is tracked in [GitHub issues](https://github.com/DayTF/blacksmith-vr/issues).
The current priority is visual feedback (#35), thermal behavior (#10), local
purification (#11), then broader manipulation and XR integration (#15).
