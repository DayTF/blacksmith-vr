import json
import unittest

from tools.inspect_hot_flow_stress import DEFAULT_SOURCE, flow_stress_pa


class HotFlowStressTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = json.loads(DEFAULT_SOURCE.read_text(encoding="utf-8"))[
            "hot_compression_reference"
        ]

    def test_matches_published_plot(self):
        # Approximate solid-line values read from Figure 4 at true strain 0.5.
        for temperature, rate, expected_mpa in [(900, 0.1, 110), (1000, 1, 106),
                                                 (1100, 10, 110), (1280, 100, 100)]:
            with self.subTest(temperature=temperature, rate=rate):
                actual = flow_stress_pa(self.reference, temperature, 0.5, rate)
                self.assertAlmostEqual(actual / 1_000_000, expected_mpa, delta=3)

    def test_rejects_extrapolation(self):
        cases = [(899, 0.5, 1), (1281, 0.5, 1), (1000, 0, 1),
                 (1000, 1.01, 1), (1000, 0.5, 0.09), (1000, 0.5, 101),
                 (1000, 0.5, float("nan"))]
        for inputs in cases:
            with self.subTest(inputs=inputs):
                with self.assertRaises(ValueError):
                    flow_stress_pa(self.reference, *inputs)
