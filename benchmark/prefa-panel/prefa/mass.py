from .geometry import Panel


def sandwich_mass_kg(
    panel: Panel,
    outer_thickness_m: float,
    inner_thickness_m: float,
    insulation_thickness_m: float,
    outer_density_kg_m3: float = 2400.0,
    inner_density_kg_m3: float = 2400.0,
    insulation_density_kg_m3: float = 35.0,
) -> float:
    """Masse d'un panneau sandwich, réservations traversantes déduites."""
    values = (
        outer_thickness_m, inner_thickness_m, insulation_thickness_m,
        outer_density_kg_m3, inner_density_kg_m3, insulation_density_kg_m3,
    )
    if any(value < 0 for value in values):
        raise ValueError("Épaisseurs et densités négatives interdites")

    surface = panel.net_area_m2()
    outer = surface * outer_thickness_m * outer_density_kg_m3
    inner = surface * inner_thickness_m * inner_density_kg_m3
    insulation = surface * insulation_thickness_m * inner_density_kg_m3
    return outer + inner + insulation
