#!/usr/bin/env python3
"""Evaluate an in-domain, source-backed hot-compression reference in pascals."""

import argparse
import json
import math
from pathlib import Path

DEFAULT_SOURCE = Path(__file__).resolve().parents[1] / "data/research/aisi_1045_sources.json"


def flow_stress_pa(reference: dict, temperature_c: float, true_strain: float,
                   strain_rate_per_s: float) -> float:
    inputs = {
        "temperature_c": temperature_c,
        "true_strain": true_strain,
        "strain_rate_per_s": strain_rate_per_s,
    }
    for name, value in inputs.items():
        lower, upper = reference["input_bounds"][name]
        if not math.isfinite(value) or not lower <= value <= upper:
            raise ValueError(f"{name} must be between {lower} and {upper} for this fit")
    c = reference["coefficients"]
    log_stress_mpa = (
        math.log(c["a_mpa"])
        + c["m1"] * temperature_c
        + c["m2"] * math.log(true_strain)
        + (c["m3"] + c["m8"] * temperature_c) * math.log(strain_rate_per_s)
        + c["m4"] / true_strain
        + c["m5"] * temperature_c * math.log1p(true_strain)
        + c["m7"] * true_strain
        + c["m9"] * math.log(temperature_c)
    )
    return math.exp(log_stress_mpa) * 1_000_000.0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("temperature_c", type=float)
    parser.add_argument("true_strain", type=float)
    parser.add_argument("strain_rate_per_s", type=float)
    args = parser.parse_args()
    reference = json.loads(DEFAULT_SOURCE.read_text(encoding="utf-8"))["hot_compression_reference"]
    try:
        stress_pa = flow_stress_pa(reference, args.temperature_c, args.true_strain, args.strain_rate_per_s)
    except ValueError as error:
        parser.error(str(error))
    print(f"{stress_pa:.8g} Pa")


if __name__ == "__main__":
    main()
