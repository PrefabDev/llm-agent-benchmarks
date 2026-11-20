def can_lift(mass_kg: float, capacity_kg: float, safety_factor: float = 1.0) -> bool:
    """Vérifie que la capacité du moyen de levage est suffisante."""
    if mass_kg < 0 or capacity_kg < 0 or safety_factor < 1:
        raise ValueError("Masse/capacité invalides ou coefficient de sécurité < 1")
    return mass_kg <= capacity_kg
