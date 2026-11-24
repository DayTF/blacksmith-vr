# Blacksmith VR — repository instructions

## Goal and authority

Build a single-room VR blacksmithing simulator. The player forges through tracked
arm movements: heat, hammer, spread, fold, forge-weld, quench, name the product,
then keep a static item with permanent craftsmanship stats. No button-driven
hammering, locomotion, MMO, other professions, or multi-room expansion.

The user's **Blacksmith VR — Technical Design Document**, sections 1–13, is the
original specification. This guide preserves its implementation constraints and
the subsequent decisions below. GitHub issues contain acceptance criteria and
references to those sections. Later explicit user decisions supersede the
original text. Do not silently resolve conflicting or unspecified gameplay or
physical rules: create a `question` issue, describe options, and ask the user.
Routine implementation details already authorized below do not need renewed
permission. Keep this guide current when decisions or public sim APIs change.

## Stack and layout

- Godot **4.7+ Standard**, GDScript, **Forward+ and Vulkan**. CI currently pins
  Godot 4.7.2 Standard. The starter project's Windows D3D12 setting was corrected
  to Vulkan with user approval.
- OpenXR with SteamVR runtime. Track the controller/hammer tip at knuckle-level
  grip; use OpenXR hand tracking when available and controller models otherwise.
- Blender → GLB assets, with PBR materials authored/imported in the engine.
- JSON for materials, defaults, process/equipment properties, recipes,
  progression, tuning and final-stat formulas.
- `src/sim/`: plain `RefCounted` classes/data, **no Node inheritance, scene-tree,
  rendering, input, audio or non-debug print calls**. Vector/math and JSON/file
  resources are acceptable. Keep the evaluator independently callable.
- `src/game/`: thin scene/UI adapters; input → sim call → visuals. No game rules
  hidden in per-frame scene code. No game-state autoload singletons; use direct
  references or a simple service locator.
- `src/vr/`: OpenXR and controller adapters.
- `assets/`, `data/`, `shaders/`, `tests/sim/`: assets, JSON, shaders and headless
  simulation suites respectively. `tests/run_all.gd` is the suite entrypoint.

## Accepted simulation and material design

### Granular matter and mechanics

- Use a granular 3D grid/matrix of matter above molecular scale. Preserve local
  position, velocity, mass, material composition/identity, temperature,
  orientation (including layer direction), impurity mass and deformation history.
- The user authorized choosing the numerical method, grid dimensions/spacing,
  flat-anvil constraints and reproducible synthetic strikes. Start with a spring
  grid; keep numerical/physical tuning configurable. These are prototype choices,
  not permission to change gameplay requirements.
- Connections have modifiable rest length, stiffness and damping. Below yield,
  deformation is elastic; above temperature-dependent yield strength, rest length
  changes permanently. Hammer mass and tracked tip velocity apply an impulse
  over a configurable face/contact area.
- **Plastic spreading**, not temporary elastic stretching, enables forging
  purification. Track discarded slag/scale mass explicitly and subtract it from
  affected surface elements. Visible debris can wait for visual milestones.
- Support cracks and weak weld interfaces. The original ductility threshold vs
  final ductility-stat distinction remains a material/curve composition concern;
  do not invent a universal hard-coded cracking temperature or formula. The user
  has now approved the M0 damage model in #27: trial plastic strain in **both
  compression and tension** accumulates fracture damage as increment/ductility(T).
  Break at damage >= 1 before committing that increment's plastic rest-length
  change. Zero ductility breaks on any attempted plastic increment. Fracture
  damage is separate from recoverable work-hardening strain; reheating does not
  heal it. This supersedes the unreviewed tensile-only prototype behavior.
- Thermal transport includes conduction, Newton cooling, radiation and
  medium-dependent quenching. Heating obeys equipment limits.

### Curves and composition

- All per-material behavior comes from data. Adding a metal is adding a file,
  with zero code changes. Never branch on material IDs.
- Use composable property graphs/curves. Each property is separate; combine
  properties to determine process outcomes. At minimum support linear, cubic
  (Catmull-Rom or natural spline) and step keyframe interpolation, scalar/vector
  values, runtime queries and shared defaults for omitted curves.
- Required properties: Young's modulus, yield strength, hardness, thermal
  conductivity, specific heat, density, melting/phase behavior, emissivity,
  temperature→RGB color, quench response and ductility. Curves can depend on
  temperature, strain and optional strain rate/pressure/process/medium.
- Work hardening and reheating recovery must use curves. Phase thresholds are
  discrete events/modifiers supporting scale, offset or curve replacement.
- The user permits provisional fantasy material data for M0. Mark it as tuning
  data, not sourced metallurgy. Real metals require sourced metallurgical curves.
- Additional approved properties: weldability, oxidation and thermal expansion.
  Magnetism/electrical conductivity are possible later properties; no gameplay
  depending on them is currently specified.

### Impurities and purification

- Every material file must contain `impurities`, even when empty. Each impurity
  defines starting concentration, process eligibility/curves and final effects.
- **Forging purification is local and surface-only**: exposed matter undergoing
  permanent plastic spreading may release impurities in the appropriate process
  conditions. Interior matter and purely elastic flexing do not purify.
- Remove a configurable **fraction of remaining impurity mass**. This supersedes
  the original absolute `removal_per_strain × strain` subtraction interpretation.
  Retain all unremoved impurities through forging and solidification.
- Spreading changes exposed material. Folding buries surfaces; subsequent
  deformation can expose previously internal material. Do not treat the entire
  billet as exposed or purify all nodes on every strike.
- Multiple purification processes are supported. Melting, flotation/sinking and
  separation use data-driven rates rather than fluid simulation. Eligibility
  depends on the impurity, metal/alloy and equipment. Some alloys do not separate
  impurities, and some furnaces cannot reach a material's melting temperature.
- Melting/separation alone does not remove impurities. Explicit skimming/draining
  removes separated matter and records discarded mass. Represent separation and
  actual removal as distinct operations.

### Damascus, folding and welding

- Support both folded single-material billets and stacked/folded different metals.
  Preserve local composition, orientation, layer identity and impurity locations;
  do not homogenize the billet when folding.
- Contacting layers do not bond automatically. Hammering under data-defined
  welding conditions creates bonds. Bad welds remain weak interfaces.
- M0 uses scripted stacking/folding/welding; tracked VR manipulation follows later.
- Finished layered items retain their material constituents; the original single
  `material_id` reference is insufficient for a multi-material item.

## Lifecycle and final items

The simulation is live only during forging. Heating, hammering, folding, welding
and quenching may repeat. Naming a product freezes the grid, creates a static
mesh/item and stores it in the collection. Never continue stepping a named item.
Final stats are immutable and include:

- Purity: 1 minus remaining impurity concentrations summed over the billet.
- Hardness and ductility: material/strain state with remaining-impurity effects.
- Shape fidelity when a target recipe is active.
- Strike quality: correct-temperature hits / total hits.
- Craftsmanship: a recipe-defined composite of those stats.

Retain the assigned name, constituent material references and relevant history.
Bake impurity effects at solidification. Exact final-stat aggregation, penalty
formulas, recipe matching and craftsmanship weights need clarification before
their implementation; do not invent them in scripts.

## Milestones, scene and performance

- **M0 (#1)**: standalone headless synthetic forging prototype, position logs,
  purification, layered material behavior and performance measurements.
  **Hard prerequisite:** validate M0 before scene/VR integration.
- **M1 (#2)**: temperature-colored live mesh and tracked hammer input.
- **M2 (#3)**: approximately 4 m × 6 m room: forge at back, anvil central, quench
  tank to side, wall tool rack, player start at front; about 5–10 active lights.
- **M3 (#4)**: complete crafting, naming/solidification and collection loop.
- **M4 (#5)**: effects, sound, comfort and performance pass.
- **M5 (#6)**: SteamVR build, Steam page and demo.

Target approximately 5,000 nodes / 15,000 connections, **<1 ms per sim step**,
and 90 Hz / approximately 11 ms total frame time. Measure warmed steps separately
from logging/startup. Report misses honestly; reducing resolution or moving the
hot loop to C++ is a spec change to discuss, not a silent optimization.

Visual requirements: temperature-driven HDR emission above 1, lighting nearby
surfaces via SDFGI/equivalent; depth/fresnel/rippling water and rougher absorbing
oil; splash particles and tank-local steam/fog; forge particles/light/fog;
plastic-strain sparks; PBR tools. Impurity visuals are optional. Positional
elastic ping/plastic thunk crossfade depends on strain ratio. Expose hammer mass,
face radius, damping, audio and emission tuning. No locomotion; comfort options
and XR performance must be tested on hardware before claiming readiness.

## Issue, branch and PR workflow

Repository: **https://github.com/DayTF/blacksmith-vr** (private), default `main`.

1. Create an issue **before** every task, feature or fix. Titles: `[M#] Short
   description`. Include acceptance criteria, original-spec section references,
   milestone and subsystem labels. Link tasks as sub-issues of milestone issues.
2. Pick the next actionable task and work sequentially. Use `feat/...`, `fix/...`
   or `chore/...` feature branches; use Conventional Commits.
3. Track `Open → status/in-progress → status/in-review → closed/Done`. A failed
   review returns work to in-progress. Keep parent milestone issues open until
   all their acceptance criteria are satisfied.
4. Open a PR to `main` with `Closes #N`, `Fixes #N` or `Part of #N`. Explain
   behavior, verification and deviations; include screenshots/video for visuals.
5. Wait for required CI on the PR's current commit, fix failures, then merge.
   **The user explicitly authorizes automatic merges of passing PRs and continued
   work without repeated confirmation.** Check CI before merging; do not bypass it.
6. Update local `main`, close/clean up completed issue status labels and continue.
   Keep the workspace clean and preserve existing user changes.

### Sustained autonomous work

The expected default is to **continue implementing**, not to end after a plan,
commit, passing test, issue, PR, merge, or milestone. Select the next actionable
issue after each merge and do as much authorized work as practical. Do not ask
whether to continue or whether to merge a passing PR. Automatic merges are
authorized, but only after checking CI for the current head and reviewing the
change against its issue. Diagnose failures and fix them before moving on.

Stop only for a genuine external blocker or required design decision, a useful
user-testing checkpoint, or a justified context handoff. Do available independent
work when a dependency is blocked, unless an unresolved spec ambiguity requires
stopping under the original instructions. Do not guess missing physical/gameplay
rules to keep moving. Keep issues and this guide sufficient for another session
to resume without the original conversation.

Suggest user testing when there is enough **in-game content or interesting visible
behavior** to evaluate. Supply launch instructions, concrete things to try and
known limitations. Do not interrupt for a headless library or routine unit-test
result. Continue independent work while awaiting optional feedback; wait when a
hardware/feel decision is a real prerequisite. Do not claim XR testing without
actual hardware evidence.

Do not publish a Steam release or otherwise message people without the specific
authorization/access required for that action. Creating project issues and PRs
and merging passing PRs are already authorized.

## Verification and session continuity

Run with Godot Standard 4.7+ (`godot` below means your installed binary):

```sh
godot --headless --path . --editor --import --quit
godot --headless --path . --script tests/check_scripts.gd
godot --headless --path . --script tests/run_all.gd
git diff --check
```

Editor import can exit zero while reporting script errors; CI also checks its
log for errors. `tests/check_scripts.gd` compiles every source/test script, including
unreferenced scripts; CI checks both compile and test logs for engine/script errors.
Suites are `tests/sim/**/test_*.gd`, extend `RefCounted`, and expose
`run() -> PackedStringArray` with failure messages, empty on success. Test physical
invariants and boundary/failure cases rather than restating implementations.
The initial runner reports bootstrap-only status when no suites exist; this does
not validate any simulation behavior or performance.

Sandbox network/DNS errors do **not** establish invalid GitHub credentials. Retry
necessary `gh`/Git commands with the permitted sandbox escalation mechanism.
Do not expose tokens or alter authentication unnecessarily. Do not commit
`.godot/`, `.codex/`, `.agents/`, `.aws/` or credentials. A Godot 4.7.2 Linux binary
was downloaded and checksum-verified at
`/tmp/blacksmith-setup/godot/Godot_v4.7.2-stable_linux.x86_64`; `/tmp` is ephemeral.

When context is heavy and the next task does not need the conversation history,
use the repository's `skills/blacksmith-continue/SKILL.md` to prepare a durable
handoff. Prefer completing the current issue and merging passing work first.
Record the exact commit/branch, next issue, verification state, unresolved work,
and preserved user changes. Suggest a fresh session only at a useful boundary;
do not use it as a routine reason to stop after each PR or mid-debugging.
The skill can start a separate task when the available host tool's explicit
user-request requirement is met; it cannot reset this conversation or manufacture
authorization. Otherwise leave a concise ready-to-use continuation prompt.

Suggest a player test when enough **in-game** interaction exists to evaluate it
(typically M1 tracked hammering, then M3's full loop). A headless library alone
is not a playable build. State actual hardware coverage and remaining limitations.

## M0 material API and schema (issue #8)

`src/sim/material_curve.gd`, `material_definition.gd` and `material_library.gd`
are plain RefCounted classes with explicit preloads, usable without editor import.

```gdscript
const Materials = preload("res://src/sim/material_library.gd")
var materials = Materials.new()
if not materials.load_directory("res://data/materials"):
    # Caller reports materials.errors; the sim itself does not print.
    return
var state = {"temperature": 1000.0, "plastic_strain": 0.2}
var hardness = materials.sample("prototype_mithril", "hardness", state)
var material = materials.get_material("prototype_mithril")
var events = material.phase_events(1300.0, 1500.0)
```

- Directory loading discovers all JSON files except `defaults.json` (configurable
  filename). Reload is atomic: invalid data leaves the last valid catalog intact.
  `material_ids()` returns sorted IDs; `get_material()` returns null for unknown IDs.
- Version 1 defaults contain `schema_version: 1` and `curves`. Materials require
  `schema_version: 1`, nonempty `id`/`name` and `impurities: []` or an impurity list.
  Omitted material curves inherit defaults. No material registration code exists.
- A graph is exactly one of `{ "constant": scalar_or_vector }`,
  `{ "axis": "temperature", "interpolation": "linear", "keys": [[x, y], ...] }`,
  or `{ "op": "multiply", "inputs": [graph, graph, ...] }`.
  Operations: `add`, `multiply`, `min`, `max`; scalars broadcast over vectors.
  `axis` defaults to `temperature`, interpolation to `linear`; `unit` is metadata.
- Keys are finite, strictly increasing and nonempty, with consistent scalar or
  vector shape. Linear, step and nonuniform Catmull-Rom cubic are supported.
  Out-of-range inputs clamp to endpoint values. Step selects the key at/below x.
  Cubic can overshoot; use explicit min/max graphs where bounds are required.
- Sampling returns a float or PackedFloat64Array. Missing/non-finite inputs,
  unknown properties/materials, invalid definitions and non-finite outputs return
  null. Callers must supply local temperature and every axis a graph uses; do not
  silently substitute a material state. `new(...).errors` reports bad graphs.
- Temperature inputs are degrees Celsius; other physical values use the `unit`
  metadata. `plastic_strain` is dimensionless accumulated work-hardening strain.
  `plastic_strain_increment` is the current increment used by impurity-removal
  graphs; accumulated strain alone must never trigger continued purification.
  Hardness composes temperature and strain; `work_hardening_recovery` supplies a
  temperature-dependent rate for the future thermal/mechanical solver.
- `phase_transitions` have unique `id`, distinct `temperature` thresholds and
  `modifiers` keyed by property. A modifier optionally replaces `curve`, then
  applies `scale`, then `offset`. Sorted thresholds accumulate at/above their
  temperatures and deactivate on cooling; no hysteresis/irreversibility is
  currently authored. `phase_events(old, new)` emits all entry/exit events in
  crossing order, including exact-threshold crossings, without double emission.
- Material `processes` and impurity `processes` have explicit `enabled` booleans,
  optional `curves`, and data such as `requires_surface`, `separates_to` and
  `requires_explicit_removal`. Graph paths are `processes.<process>.<property>`
  and `impurities.<id>.<process>.<property>`. Eligibility metadata is retained in
  `material.raw_data` (treat as read-only); sampling a graph **does not authorize
  a process or perform purification**. The future solver must enforce eligibility,
  surface exposure, plastic spreading, equipment limits and mass accounting.
- Each impurity requires a unique id and finite `base_concentration` in [0,1];
  total starting concentration cannot exceed 1. Effects are retained as data,
  with final-stat formulas still pending clarification.
- `defaults.json`, `prototype_mithril.json` and `prototype_embersteel.json` contain
  **provisional fantasy tuning data**. Mithril has a high melting range, one
  separable impurity and one bound impurity; the contrasting alloy disables melt
  purification. These files do not establish real-world metallurgy.

The material and granular mechanics layers have correctness tests. M0 remains
open: thermal transport (#10), surface purification (#11), folding/welding (#12),
melt separation (#13), and the complete forging harness (#14) remain. No playable
scene or XR performance result exists. Do not start M1 until M0 is validated.

## M0 granular mechanics reference (issue #9)

`src/sim/granular_billet.gd` is a RefCounted reference solver. Construct with a
loaded material library and the JSON tuning from `data/sim/mechanics.json`.
`build_grid(dimensions: Vector3i, spacing_m, origin: Vector3, material_id,
temperature_c, layer_id="")` transactionally constructs an empty billet's regular
lattice. `add_node()` and `connect_nodes()` support manually assembled networks.

- Use SI units and Celsius. Nodes carry position/velocity/mass, temperature,
  material identity, pure-constituent composition, layer id/orientation, local
  impurity masses, accumulated work-hardening strain and current-step increments.
  Different materials occupy different lattice points; this solver does not
  invent a homogenization law for fractional mixtures within one point.
- `add_node(..., impurity_mass=null)` initializes impurities from the material's
  base concentrations. Explicit impurity dictionaries support processed matter.
  Grid masses use density and boundary dual volumes; they sum to density times
  the geometric billet volume. Axial boundary link areas use matching dual areas.
- Integration uses [XPBD compliance](https://mmacklin.com/xpbd.pdf) for axial
  springs, a flat frictionless inelastic anvil, and hexahedral cell volume
  constraints. Bulk response comes from `bulk_modulus(T)` in the material defaults
  (provisional fantasy tuning). This permits lateral plastic spreading while
  approximately preserving local volume. Cells use six tetrahedra for signed
  volume/analytic gradients and deactivate if any structural edge breaks.
- Links expose rest/initial length, area, stiffness, damping, fracture damage and
  broken state. Young's modulus/yield/ductility use the weaker endpoint's curves;
  bulk response uses the weakest cell constituent. These are prototype assembly
  choices, not claims of calibrated metallurgy. Return mapping changes rest
  length above yield. Node strain increments average incident link contributions
  by reference volume; `plastic_spreading_increment` counts permanent extension.
- The approved #27 fracture model applies to both compression and tension and
  commits damage separately from recoverable work-hardening strain. Fracturing
  trial increments do not change rest length or apply work hardening.
- Layer orientation follows the deformed grid's local frame. Degenerate or
  cracked frames retain their previous valid orientation. Manual networks without
  cells preserve their explicit input orientation until a caller transforms it.
- `hammer(center, outward_normal, radius, hammer_mass, velocity)` contacts the
  foremost covered nodes. An inelastic effective mass accounts for the continuing
  hammer; distributing impulse by contacted mass avoids launching a tiny grain
  with the entire hammer momentum. `last_impulse` records delivered momentum.
  Impact transfer, face depth/tolerance and numerical tuning live in JSON.
- `step(dt)` uses data-defined substeps/iterations and timestep bounds. Candidate
  arrays retain the prior mechanical state if validation fails. The solver
  samples temperature/accumulated-strain graphs; extra pressure/rate-dependent
  mechanics inputs are not currently computed. Curves requiring missing inputs
  fail explicitly rather than substituting values.
- Analytic constraint corrections update velocity without subtracting nearly
  identical float positions. Pairwise damping is implicit and conserves internal
  momentum. Anvil impulses are external. Mechanical deformation preserves
  material/impurity mass; `total_mass()` includes `discarded_mass` for subsequent
  purification accounting. Mechanics itself does not discard or purify matter.

Correctness coverage includes elastic recovery, permanent yielding, compression
and tension damage, reheating not healing damage, real-material-scale stability,
impurity initialization, layer rotation, bounded contact impulses, anvil contact,
volume gradients, flattening/spreading, mass/momentum and rejected-step atomicity.

### Performance gate: not met

Run `godot --headless --path . --script tests/benchmark_mechanics.gd` for the
opt-in mechanics benchmark; fixture parameters are in mechanics.json. Timings
exclude startup, grid construction and output. `benchmarks/mechanics-baseline.json`
records the initial reference result: 5,000 nodes, 14,050 links, 4,104 volume cells,
4 substeps × 8 iterations, five samples after two warmup steps, on WSL with a
Ryzen 9 5900X. Median step time was **2,525.593 ms**, versus **<1 ms** required.
This is a severe miss, not a 90 Hz-ready solver. The benchmark is not an XR test.

The GDScript implementation is a correctness reference, not an approved runtime
performance solution. Native acceleration, a different solver/resolution, or
relaxing the budget needs a user decision under the original risk/portability
rules. Keep M0 and M1 gated; do not silently reduce node count or change language.
