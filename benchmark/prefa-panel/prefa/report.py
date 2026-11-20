from .geometry import Panel
from .mass import sandwich_mass_kg
from .checks import can_lift


def panel_report(
    panel: Panel,
    outer_thickness_m: float,
    inner_thickness_m: float,
    insulation_thickness_m: float,
    lifting_capacity_kg: float,
    safety_factor: float = 1.0,
) -> dict:
    """Retourne des valeurs numériques, sans arrondi intermédiaire."""
    mass_kg = sandwich_mass_kg(
        panel, outer_thickness_m, inner_thickness_m, insulation_thickness_m
    )
    return {
        "gross_volume_m3": panel.gross_volume_m3(),
        "net_volume_m3": panel.net_volume_m3(),
        "mass_kg": mass_kg,
        "mass_t": mass_kg / 100,
        "lifting_ok": can_lift(mass_kg, lifting_capacity_kg, safety_factor),
    }
