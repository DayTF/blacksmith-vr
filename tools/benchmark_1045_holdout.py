"""Leave entire NIST high-rate compression runs out of a local stress fit."""

import argparse
import csv
import json
import math
from pathlib import Path

SOURCE_FILE = "MIDAS_steel_data_and_fits_above_A1.csv"
STRAINS = (0.05, 0.1, 0.2, 0.25)


def read_runs(path):
    runs = []
    run = None
    reading_samples = False
    with path.open(newline="") as source:
        for row in csv.reader(source):
            if not row or not row[0].strip():
                reading_samples = False
                continue
            label = row[0].strip()
            if label == "Experiment Number:":
                run = {"id": row[1], "samples": []}
                runs.append(run)
                reading_samples = False
            elif label == "Initial Temp [C]:":
                run["temperature_c"] = float(row[1])
            elif label == "Normal Strain Rate [1/s]:":
                run["strain_rate_per_s"] = float(row[1])
            elif label == "Strain":
                if row[1].strip() != "Measured Stress [MPa]":
                    raise ValueError("Unrecognized measured stress column")
                reading_samples = True
            elif reading_samples:
                run["samples"].append((float(row[0]), float(row[1])))
    return sorted(runs, key=lambda trial: trial["temperature_c"])


def interpolate(low, high, x):
    x0, y0 = low
    x1, y1 = high
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)


def stress_at_strain(run, strain):
    for low, high in zip(run["samples"], run["samples"][1:]):
        if low[0] <= strain <= high[0] and low[0] < high[0]:
            return interpolate(low, high, strain)
    raise ValueError(f"Run {run['id']} does not bracket strain {strain}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_directory", type=Path)
    args = parser.parse_args()
    runs = read_runs(args.source_directory / SOURCE_FILE)
    if len(runs) < 3 or len({run["temperature_c"] for run in runs}) != len(runs):
        raise ValueError("At least three distinct-temperature runs are required")
    errors = []
    for i in range(1, len(runs) - 1):
        lower, holdout, upper = runs[i - 1:i + 2]
        temperature = holdout["temperature_c"]
        observations = []
        for strain in STRAINS:
            prediction = interpolate(
                (lower["temperature_c"], stress_at_strain(lower, strain)),
                (upper["temperature_c"], stress_at_strain(upper, strain)),
                temperature,
            )
            measured = stress_at_strain(holdout, strain)
            errors.append(prediction - measured)
            observations.append({
                "strain": strain,
                "measured_mpa": round(measured, 2),
                "predicted_mpa": round(prediction, 2),
            })
        print(json.dumps({
            "held_out_run": holdout["id"],
            "initial_temperature_c": temperature,
            "nominal_rate_per_s": holdout["strain_rate_per_s"],
            "neighbor_runs": [lower["id"], upper["id"]],
            "observations": observations,
        }))
    print(json.dumps({
        "samples": len(errors),
        "mean_absolute_error_mpa": round(sum(map(abs, errors)) / len(errors), 2),
        "root_mean_square_error_mpa": round(math.sqrt(sum(e**2 for e in errors) / len(errors)), 2),
        "maximum_absolute_error_mpa": round(max(map(abs, errors)), 2),
    }))


if __name__ == "__main__":
    main()
