import unittest

from prefa.geometry import Panel, Opening
from prefa.mass import sandwich_mass_kg
from prefa.checks import can_lift
from prefa.report import panel_report


class TestGeometry(unittest.TestCase):
    def test_gross_volume(self):
        self.assertAlmostEqual(Panel(3, 2.5, 0.2).gross_volume_m3(), 1.5)

    def test_net_volume_one_opening(self):
        panel = Panel(3, 2.5, 0.2, [Opening(1, 0.5)])
        self.assertAlmostEqual(panel.net_volume_m3(), 1.4)

    def test_net_volume_two_openings(self):
        panel = Panel(3, 2.5, 0.2, [Opening(1, 1), Opening(0.5, 1)])
        self.assertAlmostEqual(panel.net_volume_m3(), 1.2)

    def test_invalid_panel_size(self):
        with self.assertRaises(ValueError):
            Panel(3, 0, 0.2)

    def test_invalid_opening_area(self):
        with self.assertRaises(ValueError):
            Panel(1, 1, 0.2, [Opening(2, 1)])


class TestMass(unittest.TestCase):
    def test_sandwich_without_opening(self):
        panel = Panel(3, 2.5, 0.29)
        self.assertAlmostEqual(sandwich_mass_kg(panel, 0.07, 0.12, 0.10), 3446.25)

    def test_sandwich_with_opening(self):
        panel = Panel(3, 2.5, 0.29, [Opening(1, 1)])
        self.assertAlmostEqual(sandwich_mass_kg(panel, 0.07, 0.12, 0.10), 2986.75)

    def test_no_insulation(self):
        panel = Panel(2, 2, 0.2)
        self.assertAlmostEqual(sandwich_mass_kg(panel, 0.10, 0.10, 0), 1920)

    def test_negative_density_refused(self):
        with self.assertRaises(ValueError):
            sandwich_mass_kg(Panel(2, 2, 0.2), 0.1, 0.1, 0, inner_density_kg_m3=-1)


class TestLifting(unittest.TestCase):
    def test_no_safety_factor(self):
        self.assertTrue(can_lift(3000, 3000))

    def test_with_safety_factor(self):
        self.assertFalse(can_lift(3000, 3500, 1.2))

    def test_safety_factor_at_boundary(self):
        self.assertTrue(can_lift(3000, 3600, 1.2))

    def test_invalid_safety_factor(self):
        with self.assertRaises(ValueError):
            can_lift(1000, 2000, 0.9)


class TestReport(unittest.TestCase):
    def test_report_without_opening(self):
        panel = Panel(3, 2.5, 0.29)
        report = panel_report(panel, 0.07, 0.12, 0.10, 4000)
        self.assertAlmostEqual(report['mass_kg'], 3446.25)
        self.assertAlmostEqual(report['mass_t'], 3.44625)
        self.assertAlmostEqual(report['net_volume_m3'], 2.175)
        self.assertTrue(report['lifting_ok'])

    def test_report_with_opening_and_safety(self):
        panel = Panel(3, 2.5, 0.29, [Opening(1, 1)])
        report = panel_report(panel, 0.07, 0.12, 0.10, 3500, safety_factor=1.2)
        self.assertAlmostEqual(report['net_volume_m3'], 1.885)
        self.assertAlmostEqual(report['mass_t'], 2.98675)
        self.assertFalse(report['lifting_ok'])


if __name__ == '__main__':
    unittest.main()
