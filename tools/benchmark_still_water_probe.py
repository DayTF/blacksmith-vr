"""Compare the preview water coefficient against a published S45C core transient."""

import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_json(relative_path):
    return json.loads((ROOT / relative_path).read_text())


def polynomial(coefficients, temperature):
    return sum(value * temperature**power for power, value in enumerate(coefficients))


def linear_curve(points, temperature):
    for (lo, first), (hi, second) in zip(points, points[1:]):
        if temperature <= hi:
            fraction = max(0, (temperature - lo) / (hi - lo))
            return first + fraction * (second - first)
    return points[-1][1]


def simulate(probe, case, coefficient, shells):
    """Advance concentric finite volumes per unit length with zero end flux."""
    inputs = probe["thermal_inputs"]
    radius = probe["diameter_m"] / 2
    dr = radius / shells
    faces = [2 * math.pi * i * dr for i in range(shells + 1)]
    masses = [
        inputs["density_kg_m3"] * math.pi * dr**2 * (2 * i + 1)
        for i in range(shells)
    ]
    # Explicit diffusion step with a conservative Fourier number for this grid.
    dt = 0.15 * dr**2 / 1e-5
    bath = case["bath_c"]
    threshold = probe["crossing_temperature_c"]
    temperature = [probe["initial_temperature_c"]] * shells
    samples = case["figure_16_core_c_at_s"]
    prediction = []
    crossing = None
    time = 0.0
    while (len(prediction) < len(samples) or crossing is None) and time < 30:
        previous = temperature[0]
        flux = [0.0]
        for i in range(1, shells):
            interface = (temperature[i - 1] + temperature[i]) / 2
            conductivity = polynomial(inputs["conductivity_w_mk"], interface)
            flux.append(faces[i] * conductivity * (temperature[i - 1] - temperature[i]) / dr)
        outer = temperature[-1]
        conductivity = polynomial(inputs["conductivity_w_mk"], outer)
        # Face temperature is reconstructed through the outer half shell.
        h = coefficient(outer)
        surface = bath + (outer - bath) / (1 + h * dr / (2 * conductivity))
        h = coefficient(surface)
        flux.append(faces[-1] * (outer - bath) / (1 / h + dr / (2 * conductivity)))
        temperature = [
            local + dt * (flux[i] - flux[i + 1])
            / (masses[i] * polynomial(inputs["specific_heat_j_kgk"], local))
            for i, local in enumerate(temperature)
        ]
        core = temperature[0]
        if not bath <= core <= previous:
            raise RuntimeError("Core temperature left its cooling bounds")
        if crossing is None and core <= threshold:
            cooling_rate = (previous - core) / dt
            crossing = (time + (previous - threshold) / cooling_rate, cooling_rate)
        while len(prediction) < len(samples) and samples[len(prediction)][0] <= time + dt:
            sample_time = samples[len(prediction)][0]
            prediction.append(previous + (core - previous) * (sample_time - time) / dt)
        time += dt
    if crossing is None or len(prediction) != len(samples):
        raise RuntimeError("Probe failed to reach all benchmark observations")
    return crossing, prediction


def main():
    probe = read_json("data/research/still_water_probe.json")
    environments = read_json("data/preview/environments.json")["environments"]
    water = next(environment for environment in environments if environment["id"] == "water")
    defaults = read_json("data/materials/defaults.json")["curves"]
    curve = defaults[water["coefficient_property"]]
    if curve["interpolation"] != "linear" or curve["axis"] != "temperature":
        raise ValueError("Expected the preview water coefficient to be linear in temperature")

    def coefficient(temperature):
        return water["coefficient_scale"] * linear_curve(curve["keys"], temperature)

    for case in probe["cases"]:
        coarse_crossing, coarse_samples = simulate(probe, case, coefficient, 16)
        (crossing_s, rate), samples = simulate(probe, case, coefficient, 32)
        if (abs(crossing_s - coarse_crossing[0]) > 0.01
                or abs(rate - coarse_crossing[1]) > 0.5
                or max(abs(a - b) for a, b in zip(samples, coarse_samples)) > 1):
            raise RuntimeError("Probe result changed under radial and timestep refinement")
        measured_rate = case["figure_18_rate_c_s"]
        print(json.dumps({
            "bath_c": case["bath_c"],
            "modeled_727_crossing_s": round(crossing_s, 3),
            "modeled_727_rate_c_s": round(rate, 2),
            "measured_727_rate_c_s": measured_rate[0],
            "digitized_727_rate_bounds_c_s": measured_rate[1:],
            "core_transient": [
                {"time_s": time, "modeled_c": round(model, 1),
                 "measured_c": measured, "digitized_bounds_c": [low, high]}
                for model, (time, measured, low, high)
                in zip(samples, case["figure_16_core_c_at_s"])
            ],
        }))


if __name__ == "__main__":
    main()
