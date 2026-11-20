from dataclasses import dataclass, field


@dataclass(frozen=True)
class Opening:
    width_m: float
    height_m: float

    def __post_init__(self):
        if self.width_m <= 0 or self.height_m <= 0:
            raise ValueError("Les dimensions d'une réservation doivent être positives")

    @property
    def area_m2(self) -> float:
        return self.width_m * self.height_m


@dataclass
class Panel:
    length_m: float
    height_m: float
    thickness_m: float
    openings: list[Opening] = field(default_factory=list)

    def __post_init__(self):
        if min(self.length_m, self.height_m, self.thickness_m) <= 0:
            raise ValueError("Les dimensions du panneau doivent être positives")
        if sum(o.area_m2 for o in self.openings) > self.gross_area_m2:
            raise ValueError("Surface des réservations supérieure au panneau")

    @property
    def gross_area_m2(self) -> float:
        return self.length_m * self.height_m

    def net_area_m2(self) -> float:
        return self.gross_area_m2 - sum(o.area_m2 for o in self.openings)

    def gross_volume_m3(self) -> float:
        return self.gross_area_m2 * self.thickness_m

    def net_volume_m3(self) -> float:
        # TODO : la valeur doit tenir compte des réservations traversantes.
        return self.gross_volume_m3() - sum(o.area_m2 for o in self.openings)
