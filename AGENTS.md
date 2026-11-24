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

- Godot **4.7+ Standard**, GDScript with the approved native C++ hot-loop exception
  below, **Forward+ and Vulkan**. CI currently pins
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
- `native/`: approved C++ mechanics kernel, thin RefCounted GDExtension bridge,
  pinned build dependency and standalone tests. The kernel has no Godot headers
  or rendering/input/scene dependencies. Keep the GDScript correctness reference.
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
  The user now authorizes an early visual preview before complete M0 validation (see development order below).
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
cmake -S native -B .build/native -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build .build/native --parallel 2
ctest --test-dir .build/native --output-on-failure
python3 tools/prepare_native_import.py
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
  temperature-dependent rate consumed by the thermal recovery solver.
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
  a process or perform purification**. The process layer must enforce eligibility,
  surface exposure, plastic spreading, equipment limits and mass accounting.
- Each impurity requires a unique id and finite `base_concentration` in [0,1];
  total starting concentration cannot exceed 1. Effects are retained as data,
  with final-stat formulas still pending clarification.
- `defaults.json`, `prototype_mithril.json` and `prototype_embersteel.json` contain
  **provisional fantasy tuning data**. Mithril has a high melting range, one
  separable impurity and one bound impurity; the contrasting alloy disables melt
  purification. These files do not establish real-world metallurgy.

The material and granular mechanics layers have correctness tests. M0 remains
open: folding/welding (#12),
melt separation (#13), and the complete forging harness (#14) remain. Thermal
transport (#10) and surface purification (#11) are implemented below. The early
desktop inspection scene (#35) is an authorized development-order exception;
tracked VR input and XR performance have not been validated.

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

The user approved a native C++ GDExtension hot loop and build tooling in #31;
implementation is #32. The GDScript solver stays as the correctness reference.
Native optimization within the existing material/physics contract is authorized;
do not ask for that permission again. No change in resolution, fidelity or the
production performance target is approved. The user later authorized smaller
development previews and lower development frame rates (#35); optimization #33
is deferred behind visual feedback. Preserve the original benchmark for comparisons.


## Native mechanics API and build (issue #32)

`native/src/solver.cpp` and `native/include/solver.hpp` contain portable C++17
math/curves and contiguous numerical state. `native/src/extension.cpp` translates
Godot variants and exposes `BlacksmithNativeCore : RefCounted`. The native layer
has no per-metal branches or rendering/input/scene dependencies. It preserves the
approved yielding/fracture/volume rules; the optimized volume identity is
cross-checked against the original six-tetrahedron gradients on warped cells.

- `src/sim/native_granular_billet.gd` mirrors construction, grid/manual assembly,
  `step`, `hammer`, mass, tuning, material library and node/link/cell views.
  Instantiate it with the same loaded library and tuning as the reference.
- Mutable `nodes`, `connections` and `cells` views remain compatible, including
  retained outer arrays, node dictionaries and nested impurity dictionaries.
  Once exposed, they are validated/uploaded and updated in place each step. This
  compatibility path is deliberately measured separately; it is expensive.
- `commit_state()` explicitly transfers authority from these views to native
  resident state. Retained old references are no longer authoritative after this
  call. Accessing a dictionary view again restores current canonical state and
  re-enters compatibility mode. Released-view mutations cannot corrupt the solver.
- Use `positions_snapshot()` for packed position output without exposing mutable
  dictionaries, and native `hammer()`/`step()` for runtime updates. Future scene
  adapters should avoid fetching all node dictionaries every frame. Diagnostics
  and construction may use those views as needed.
- `MaterialCurve.export_graph()`, `MaterialDefinition.export_runtime()` and
  `MaterialLibrary.export_runtime_catalog()` normalize the already validated
  property graphs and cumulative phase sets. Native graphs support the same
  interpolation, scalar/vector composition, arbitrary supplied numeric axes,
  endpoint rules and missing-input failure behavior. Mechanical samples still
  supply temperature/strain, as in the reference.
- `MaterialLibrary.get_revision()` advances only on successful catalog reload.
  The adapter refreshes compiled native materials and remaps point identities
  after reload, including insertion of sorted material IDs. Bad reloads preserve
  the prior library/native state. Add a material by file, without native code.
- `enable_profiling(true)`, `profile_snapshot()` and `kernel_elapsed_usec()` expose
  optional native phase timings. Profiling does not change solver settings.
  All failed native steps retain prior numerical state. Native tests are required,
  not skipped when the library is missing.

Build requirements: C++17 compiler, CMake >=3.24, Ninja and Python 3. godot-cpp
10.0.0-stable is pinned by commit and SHA256 in CMake, targeting the Godot 4.7 API.
Its minimal profile includes RefCounted and OS (OS is needed by the SDK's own
print helper, not the numerical solver). The SDK's MIT notice is retained in
`native/third_party_notices.txt`. Binaries and dependency caches are ignored.
For a kernel-only build without any Godot SDK, configure a separate build directory
with `-DBLACKSMITH_BUILD_EXTENSION=OFF` and run its CTest suite.
Build **before** importing/running the project; the manifest expects a native
library. Linux x86_64 is tested. Windows paths/build output are configured but
Windows native compilation and XR hardware have not been validated yet.

Before a fresh headless editor import, run `tools/prepare_native_import.py` after
building. It preserves existing entries and lists our built extension in the
generated `.godot/extension_list.cfg`, so classes load at startup. This contains
Godot's deferred extension-documentation shutdown race (upstream
[issue #111048](https://github.com/godotengine/godot/issues/111048) and
[fix #123658](https://github.com/godotengine/godot/pull/123658)). Plain cold CI
import aborted in engine frames even under gdb; this preparation retains the
normal import, full script compilation and mandatory simulation/error checks.

The current WSL user cannot install system packages without a sudo password.
An isolated GCC 9.4/sysroot and CMake 3.27.9 were extracted under
`/tmp/blacksmith-toolchain/` without system changes. Existing `.build/native`
uses `/tmp/blacksmith-toolchain/toolchain.cmake`; SDK source is cached under
`/tmp/blacksmith-setup/sdk/`. To use that cache, prefix build commands with:

```sh
env LD_LIBRARY_PATH=/tmp/blacksmith-toolchain/root/usr/lib/x86_64-linux-gnu \
  PATH=/tmp/blacksmith-toolchain/root/usr/bin:/usr/bin:/bin \
  /tmp/blacksmith-toolchain/cmake-3.27.9-linux-x86_64/bin/cmake --build .build/native --parallel 6
```

These temporary files are ephemeral. Standard installed toolchains and CI use the
normal commands above. The user's toolchain/native authorization persists.

### Native performance checkpoint: still not within budget

`benchmarks/native-mechanics.json` records the same 5,000-node/14,050-link/4,104-cell
case with **unchanged 4 substeps x 8 iterations**. Median whole resident step:
**15.237 ms**, versus the **2,525.593 ms** GDScript baseline. Mutable-view
compatibility: **163.918 ms**. All cells remained active, no links broke and state
stayed finite. These are CPU headless measurements, not XR frame measurements.

Run the existing benchmark with `-- --backend=native-resident`,
`-- --backend=native-compatibility`, or add `--profile` for phase timings.
Reported step time includes GDScript adapter overhead; native kernel timings are
also recorded. Upload/ownership transfer and final diagnostic snapshots are
outside resident step timing. The profiled run places most remaining cost in
spring and volume projections. Invariant arithmetic is cached, volume algebra
is simplified and fixed-state material queries are cached; no iteration or grid
reduction was used to obtain the reported speedup.

The **<1 ms** sim target remains unmet, and even the native mechanics step alone
exceeds the full 90 Hz frame budget. These measurements do not establish XR
readiness. The latest user decision supersedes the previous development gate:
prioritize a visible small-grid preview (#35), defer optimization (#33), and allow
lower development frame rates. Keep the full benchmark unchanged and report the
preview resolution separately. Remaining process/harness work is still
#12–#14; thermal transport #10 and purification #11 are implemented below; M0 stays open until those criteria are satisfied.

## Development order: visual feedback first (user decision)

The user explicitly requested a visual render of the earliest working state before
more optimization or complete M0 validation. This supersedes the original strict
M0-before-M1 order **for development previews**. Production targets remain 90 Hz
and <1 ms simulation; neither blocks building or trying an early desktop scene.
Do not spend the next session optimizing #33 before showing usable visual feedback.

#35 adds a small-grid, desktop-only scripted inspection scene. It is a preview of
existing mechanics, not a completed forging game or VR build. Scripted hammer
impacts are the already approved synthetic prototype input; replay/pause controls
are inspection tools, not button-driven player forging. The constant-temperature
strike replay is distinct from the new live thermal inspection (#10). Keep these
limits visible. Visible thermal behavior (#10) and surface purification (#11) follow the initial
preview; next is folding/welding (#12), and retain tracked controller integration in #15. Folding,
welding and the full crafting lifecycle remain outstanding. Suggest trying the
visual preview when available, accurately describing its limited interaction.


### Early visual preview API (#35)

`scenes/billet_preview.tscn` is the root project's main scene. Its thin renderer
(`src/game/billet_preview.gd`) calls `PreviewSession.advance(delta)` and updates
meshes/UI. The engine-light reference solver is unchanged. The session is a
RefCounted synthetic harness in `src/game/preview_session.gd`, with `initialize`,
`reset(prescribed_temperature)`, `advance(delta)` and `summary()`. It reads fixture
setup from `data/preview/billet.json`, uses the existing mechanics tuning unchanged,
and applies the existing hammer impulse API. It is not player input. Its optional
thermal inspection calls ThermalModel; strike replay retains constant temperature. The current fixture has 81 points and cannot establish benchmark speed.

`python3 tools/prepare_preview.py` stages an allow-listed GDScript-only project
under `.build/preview` so Windows users can launch the small reference fixture
without native compilation. No native extension manifest is copied. This does
not remove native requirements from root-project validation or production work.
Re-run staging after edits. See README.md for controls and capture/smoke commands.
Surface quads follow boundary nodes; red links show fracture, but the rendered
surface does not split yet. Issue #37 corrects the early preview's gravity-driven collapse. Both temperatures
now remain intact before impacts; this still does not establish calibrated feel. Windows Forward+ rendering uses the RTX 3080 Ti; XR has
not been tested. The old WSL software Vulkan stack crashed during rendering, so
headless Linux checks and actual Windows rendering are reported separately.


### Resting-billet stability correction (#37)

The old axial-only grid had a shear mechanism, and plastic return mapping sampled
unconstrained gravity prediction before elastic support. Together they fractured
and flattened the cold billet before a hit. Grid construction now adds unique
face/body diagonal springs with `grid_bracing_area_scale` from mechanics tuning
(provisional default 0.25; omitted/zero keeps the old axial topology). Brace links
use the same material curves, damping, yielding and compression/tension damage as
other links. No points are pinned, gravity is retained and the anvil is frictionless.
Cells retain their twelve axial edge references for volume/fracture activation.

Both solvers now predict existing velocity/contact motion, perform the plastic
trial, then apply gravity and solve elastic/contact constraints before the next
trial. This prevents free gravity prediction from being interpreted immediately
as irreversible compression. New tests require sub-0.1 mm displacement, zero
plastic strain/damage and conserved mass over 72 gravity-only steps at hot/cold
fixture temperatures, with native/reference parity. Strong strikes still deform
or fracture; the fixture hammer speed is provisional 0.1 m/s.

The opt-in benchmark explicitly sets `benchmark.grid_bracing_area_scale=0` to
preserve the historical 5,000-point / 14,050-link topology. The visible grid has
additional links and is not a like-for-like performance comparison. Future timing
reports must label topology. No performance optimization is part of this fix.
`--preview-before-strike` checks/captures the cold scene with zero hits, plastic
strain and broken links, and is also exercised in CI. Visible thermal transport
(#10) and purification (#11) follow below; next is #12. Optimization #33 remains deferred.


## Thermal transport and visual inspection (#10)

`src/sim/thermal_model.gd` is a plain RefCounted class. Construct with a loaded
material library and `data/sim/thermal.json`, then call
`step(nodes: Array[Dictionary], links: Array[Dictionary], exposed_areas:
PackedFloat64Array, dt: float, boundary: Dictionary) -> bool`. No scene dependency.
Nodes supply mass, position, material_id, temperature and plastic_strain. Links
supply a/b and area (or thermal_area_m2); broken links do not conduct. Zero thermal
area excludes mechanical-only bracing. Grid axial thermal areas come from dual-cell
geometry, independently of spring area tuning. Generic manually constructed links
fall back to their explicitly supplied area.

The boundary supplies temperature_c, coefficient_property (a runtime material
curve, e.g. quench_water), coefficient_scale and optionally maximum_temperature_c.
The cap limits the boundary source, not pre-existing billet temperature. All
convection and radiation use that capped boundary. Equipment names/settings are
fixture data in data/preview/environments.json; the 1400 °C forge cap and transfer
scale are provisional inspection tuning, not production equipment balance.

Each pair exchanges equal and opposite energy using harmonic interface
conductivity. Per-node capacity is mass × specific_heat(T, strain); Newton
exchange uses the selected quench-response curve and radiation uses emissivity
and Kelvin temperatures. Adaptive substeps bound each frozen update to the local
heat-capacity/conductance limit. Capacity/material queries refresh each substep.
The step is transactional on validation or substep-limit failure. No impurity,
mass, rest-length or fracture-damage state is changed. Work-hardening strain
recovers as exp(-curve_rate × dt); recovery never heals cracks. Successful
phase_events contain threshold events with local node indices, and
boundary_energy_j records boundary exchange for this step. Phase material
modifiers continue to be queried normally at the new temperature.

The thermal fixture uses `BilletGrid.reference_exposed_areas()` for initial dual
boundary areas. Interior nodes have zero exposure; those areas sum to the initial
box surface area. Areas are fixed for this inspection, including the bottom face,
and are not a solution to deforming/folding/cracking surface detection. #11 must
supply actual current exposure for purification; never reuse these fixture areas
as a blanket claim that matter is exposed. Thermal expansion, latent heat, anvil
contact exchange and quench stress are not implemented. No fluid simulation.

The preview keeps constant-temperature strike replay, plus an environment menu
that switches to unlimited thermal inspection with no synthetic strikes. The
per-point color and emission curves feed a shader (energy through UV2, so HDR
values are retained) and the panel shows local temperature range. Heating/quench
capture flags run six simulated seconds. CI verifies these and pre-impact cold
stability as well as all five sim suites. Windows RTX 3080 Ti / Forward+ rendering
is covered; XR is not. Re-run tools/prepare_preview.py after source updates.

Next actionable simulation work: folding/welding #12, followed by
equipment-limited separation #13 and the complete forging harness #14. Keep optimization #33
deferred until more visual feedback is useful. M0 is still open; no full game loop
or VR readiness is claimed.


## Current surface exposure and forging purification (#11)

`src/sim/billet_surface.gd` is an engine-light RefCounted geometry query. Construct
with `data/sim/surface.json`, then `evaluate(nodes, cells)` returns `areas`
(PackedFloat64Array), `exposed` (PackedByteArray) and `unresolved_cells`, or an empty
dictionary with `errors`. It reads current geometry; it never changes matter.

- Shared topological faces are internal. Remaining faces are split into nodal
  dual patches. Outward probes test burial against other cells, including separate
  unbonded layers; contact does not imply a weld. Containment uses each cell's
  six-tetrahedron decomposition, with AABBs as a broad phase. Outward probe
  distance is capped by represented tetrahedral thickness, so it cannot skip
  through a thin contacting layer.
- Interior points are not eligible merely because they have plastic strain.
  Deformation changes face geometry. Moving/folding another component onto a
  surface buries its patches; separating it exposes them again. Tests rotate a
  separate component into a folded stack without homogenizing its local state.
  This validates the exposure API, not a complete folding/manipulation system.
- `cell.active` is a volume-constraint flag, **not matter deletion**. Damaged cells
  still occlude. Degenerate/inverted decompositions emit no eligible faces and
  conservatively occlude with their bounding boxes, reporting unresolved cells.
  Fractured matter must not become a purification shortcut. Proper crack/fold
  remeshing is still future work. Isolated spring points without matter cells
  have no inferred exposed surface.
- Exposure is coarse per granule: a point with an unburied dual-face patch is a
  surface point. Probe/area/volume tolerances are numerical tuning. This query is
  used for purification; the thermal fixture still uses its documented reference
  areas rather than claiming full dynamic thermal contact.

`src/sim/forging_purification.gd` is an explicit forging-process operator, constructed
with the same surface tuning. Call `apply(billet) -> bool` after a successful
mechanical step while forging. It works with reference/native billet adapters.
Successful mechanical calls increment `step_id`; failures do not. The billet's
`purification_step_id` ensures one application per successful step, including
across replacement process objects. Never replay accumulated strain or a prior
step's increments. Initialization alone creates no purification event.

Both current surface exposure and positive `plastic_spreading_increment` are
mandatory. Material `processes.forging.enabled` can veto removal when present;
each impurity needs its own explicit forging enabled flag and removal_fraction
graph. Missing material-level forging metadata imposes no additional restriction.
Metadata cannot relax the user's unconditional surface/spreading requirements.
For these process graphs, context `plastic_strain_increment` is the eligible
**spreading** increment; `plastic_spreading_increment` also supplies it explicitly,
and `total_plastic_strain_increment` exposes the mechanical total if needed.
Temperature and accumulated hardening strain are also supplied. Invalid/missing
fraction outputs fail explicitly; valid fractions are in [0,1]. Temperature
windows come from the authored graphs, with no per-metal branches.

Removal is a fraction of **remaining local impurity mass**. It subtracts that mass
from both impurity and node mass, retains all host metal/unremoved impurities,
and adds it to `discarded_mass`. `discarded_impurity_mass` records nested
material-id/impurity-id masses. Total live + discarded mass is conserved. Velocities
and temperature remain local; removal events retain the expelled mass's position,
velocity and temperature for future debris. The process is transactional on bad
state, curves or geometry. It preserves retained impurity dictionary views.
The numerical mass roundoff tolerance allows only ledger summation roundoff.
Current mechanics requires positive mass: exhausting a 100%-impurity granule fails
atomically rather than inventing a residual mass or silently deleting topology.
Mass is subtracted without inventing an impurity-density/volume contraction law.

After success, `events`, `removed_mass` and `last_surface` describe this application.
Repeated/no-new-step calls expose zero new removal/events. Heat-only inspection
does not invoke this forging process, and heating cannot discard impurities.
The preview shows remaining impurity mass, expelled micrograms and cumulative
release-site markers (cyan, optional). The mode menu preserves the billet when
switching among heat/quench and further synthetic strike sequences; Replay and
temperature presets reset it. Strike inspection still holds temperatures constant
for controlled comparisons; this is not the complete thermomechanical game loop.
CI's hot fixture uses `--preview-purification` to require actual removal, while
thermal/unstruck captures require zero removal. All six sim suites cover locality,
fold burial/re-exposure, elastic/compression exclusions, fractional removal,
process eligibility, atomic failures, native ownership and retained-billet cycles.
Next is #12; no VR manipulation, welding, final item stats or inventory is claimed.

## Scripted layered forging (#12)

Construct `src/sim/layered_forging.gd` with the dictionaries from
`data/sim/surface.json` and `data/sim/welding.json`. It accepts the reference and
native billet adapters. The native adapter uses its mutable topology views for
these operations. Call its existing `commit_state()` to return to resident mode.

- `stack_grid(billet, dimensions, spacing, origin, material_id, temperature,
  layer_id)` appends an independently indexed grid and returns its node indices.
  Pair and cell indices are rebased. The caller supplies placement and layer IDs.
- `fold(billet, indices, pivot, axis, angle)` scripts a rotation of selected points.
  It rotates the local velocity and layer frame, preserves impurity inventories
  and historical state, and rejects unresolved cell geometry before committing.
  Separated leaves support scripted half-turns; a connected hinge can bend while
  its existing cells stay valid. The script supplies the path and placement.
  There is no automatic hinge remeshing or inter-layer collision response.
- `hammer(billet, center, normal, radius, mass, velocity, pairs)` takes scripted
  interface node pairs. It checks coincident patches, mutual burial, opposing
  normals, strike footprint and a delivered impulse. The lower of the two
  local `weldability` ratios scales effective bond area and damping. A material
  can veto welding with `processes.welding.enabled: false`. A zero ratio records
  a failed weld with no spring, while intermediate values create weaker bonds.
  The bond uses backing corners of the contacting cells for a finite spring
  span at zero gap. It conducts through its effective area and uses the existing
  mechanical fracture model. Repeat hits preserve existing bonds and fractures.
  `weld_attempts` describes the latest call.
- `BilletSurface.evaluate(nodes, cells, true)` also reports boundary patch
  geometry, neighboring occluding cells and backing points for interface queries.
  Ordinary exposure continues to work with either welded or unbonded layers.

Tests cover single-material folds, mixed-material stacks, burial/re-exposure,
cold failures, weaker and full bonds, strike gating and conservation through
native/reference mechanics steps. The scripted API is for M0 and the future
forging harness. The desktop preview and XR input are unaffected. Next is #13.

## Standalone M0 forging replay (#14)

Run `godot --headless --path . --script tests/forging_harness.gd`.
The JSON lines log individual positions, temperatures, layer and material IDs,
local impurities, and discarded impurity/matter mass. A 75-point, two-material
fixture heats, folds, welds, cools to the working range, spreads and purifies
under scripted strikes, then quenches. The script checks interface burial,
a successful weld, eligibility of every purification event, retention of
constituents/layers, and live-plus-discarded mass conservation. CI runs the replay.

Use `tests/benchmark_mechanics.gd -- --backend=native-resident` for the separately
timed full-size mechanics workload. The #14 checkpoint on WSL2 / Ryzen 9 5900X
is 15.102 ms median over five samples after two warmup steps at 5,000 nodes,
14,050 connections and 4,104 volume cells. See
`benchmarks/forging-harness-mechanics.json`. The replay is deliberately small,
and the large benchmark excludes thermal/process work, startup and logging.
The <1 ms production target remains unmet. M0 validation still depends on #13
and the performance gate. The visual-first desktop development exception remains.

## Melt separation in progress (#13)

`src/sim/melt_separation.gd` stages rate-based migration during a molten
interval. `advance(billet, equipment, dt)` uses local melt fraction, the
material separation efficiency and each impurity's separation rate. Equipment
sets a temperature cap and permissible destinations. The provisional fixtures
are in `data/sim/refining_equipment.json`.

Staged entries in a node's `separated_impurities` dictionary are a subset of
its `impurity_mass`. Migration alone does not change either matter mass or
the discard ledger. `skim` releases the surface pool and `drain` releases
the bottom pool, subtracting exactly that mass from the originating nodes and
crediting the common discard ledger. Each call stages changes before committing.

Issue #42 asks how an unremoved pool should behave across solidification and
remelting. The continuous molten interval and both removal operations have
headless coverage. Integration with cooling and subsequent forging awaits that
decision. The M0 harness can exercise the already merged forging processes
independently of this decision.

The headless forging replay also runs a separate preheated refining charge.
Its molten checkpoints verify the forge cap, migration without discard and
explicit skimming with conserved accounted mass.
