#!/usr/bin/env python3
"""Join Xalaria 0.68's orbital catalogue and native world trait export."""
import collections
import csv
import json
import math
import sys
from pathlib import Path
from typing import NamedTuple


class World(NamedTuple):
    key: int
    radius: float
    distance: float
    period: float
    temperature: float
    material: int
    clouds: float
    rings: float
    tilt: float
    node: float
    name: str
    inclination: float = 0.
    heading: float = 0.


def read_catalogue(path):
    groups = collections.defaultdict(list)
    home = []
    stars = {}
    with path.open() as source:
        rows = csv.reader(source, delimiter="\t")
        assert next(rows)[:2] == ["XALARIA_CATALOG", "2"]
        for row in rows:
            if row[0] == "S":
                stars[int(row[1])] = (float(row[4]), float(row[5]), row[3])
            elif row[0] == "T":
                # StellarEvolution.cpp constants evaluated for these catalogue survey IDs.
                radius, temperature, mass = {
                    "red_giant": (39745027219.8632, 4498.00666556858, 1.10264808820546),
                    "neutron_star": (11563.0047748522, 107194.44823894, 1.68316655649369),
                    "brown_dwarf": (61749528.7366563, 1163.85232317334, .038527351694322),
                    "carbon_giant": (175508835262.749, 2650.51770871635, .831305497315234),
                }[row[2]]
                system = int(row[1])
                orbit_au = float(row[6])
                distance = orbit_au * 1.495978707e11
                period = math.tau * math.sqrt(distance**3 / (1.32712440018e20 * mass))
                luminosity = (radius / 6.957e8)**2 * (temperature / 5772)**4
                equilibrium = max(35., 278. * luminosity**.25 / math.sqrt(orbit_au))
                stars[system] = (radius, temperature, row[3])
                groups[system].append(World(
                    (1 << 62) | system, 1.65e6, distance, period,
                    equilibrium, 1, 0, 0, 0, 0, row[5],
                ))
            elif row[0] == "W":
                system = int(row[1])
                ring_width = max(0, float(row[23]) - float(row[22]))
                body = World(
                    int(row[3]), float(row[6]), float(row[7]), float(row[8]), float(row[11]),
                    int(row[12]), float(row[20]), ring_width,
                    float(row[24]) if ring_width and row[24] != "-" else 0,
                    float(row[25]) if ring_width and row[25] != "-" else 0, row[4],
                    float(row[9]), float(row[10]),
                )
                if system == 14538:
                    home.append((int(row[2]), int(row[5]), body))
                if row[5] == "-1":
                    groups[system].append(body)
    return stars, groups, home


def read_traits(path):
    with path.open() as source:
        rows = csv.reader(source, delimiter="\t")
        if next(rows) != ["XALARIA_WORLD_TRAITS", "1"]:
            raise ValueError("Unexpected world traits format")
        return {(int(row[0]), int(row[1])): tuple(float(x) for x in row[2:]) for row in rows}


def ranked_worlds(worlds):
    ranked = sorted(sorted(worlds, key=lambda world: world.distance),
                    key=lambda world: world.radius * (1 + min(world.rings, 2)), reverse=True)[:9]
    # The wide ocean scenes keep their original three featured planets.
    return sorted(ranked[:3], key=lambda world: world.distance) + sorted(
        ranked[3:], key=lambda world: world.distance)


def floats(values):
    return " ".join(format(v, ".8g") for v in values)


def epoch_phase(period):
    return math.tau * (1700000000. / period % 1.) if period > 0 else 0.


def write_orbits(path, stars, groups, traits):
    with path.open("w") as target:
        target.write("PELAGIC 5\n")
        for system, (radius, temperature, name) in sorted(stars.items()):
            worlds = ranked_worlds(groups[system])
            target.write(f"{system} {math.log10(radius):.9f} {temperature:.2f} {len(worlds)} "
                         f"{json.dumps(name, ensure_ascii=False)}")
            for body in worlds:
                look = traits[(system, body.key)]
                if len(look) != 20:
                    raise ValueError(f"Invalid appearance for {body.name}")
                target.write(f" {math.log10(body.radius):.9f} {math.log10(body.distance):.9f} "
                             f"{math.log10(max(body.period, 1)):.9f} {body.temperature:.3f} {body.material} "
                             f"{body.clouds:.3f} {body.rings:.3f} {body.tilt:.2f} {body.node:.2f} "
                             f"{json.dumps(body.name, ensure_ascii=False)} {floats(look)} "
                             f"{body.inclination:.9g} {body.heading:.11g} {epoch_phase(body.period):.13g}")
            target.write("\n")


def write_ziksa(path, stars, home, traits):
    indices = {world_id: index + 1 for index, (world_id, _, _) in enumerate(home)}
    with path.open("w") as target:
        target.write('// Generated by tools/derive_catalog.py from the Xalaria catalogue.\n'
                     '#pragma once\n\n#include "Sea.hpp"\n\nnamespace pelagic {\n'
                     'struct ZiksaWorld {\n'
                     '    const char* name;\n'
                     '    double radius, distance, period, inclination, heading, phase, temperature;\n'
                     '    int parent;\n'
                     '    float clouds;\n'
                     '    WorldAppearance look;\n};\n'
                     'inline constexpr std::array ziksaWorlds{\n')
        radius, temperature, name = stars[14538]
        target.write(f'    ZiksaWorld{{{json.dumps(name)},{radius:.15g},0,0,0,0,0,{temperature:.15g},-1,0,{{}}}},\n')
        for _, parent, body in home:
            data = traits[(14538, body.key)]
            rows = [", ".join(f"{value:.8e}f" for value in data[i:i+4]) for i in range(0,20,4)]
            fields = (body.radius, body.distance, body.period, body.inclination, body.heading,
                      epoch_phase(body.period), body.temperature, indices[parent] if parent >= 0 else -1)
            target.write(f"    ZiksaWorld{{{json.dumps(body.name)}," + ",".join(f"{value:.15g}" for value in fields) +
                         f",{body.clouds:.8e}f,{{" +
                         ",\n        ".join("{" + row + "}" for row in rows) + "}},\n")
        target.write('};\n} // namespace pelagic\n')


if __name__ == "__main__":
    stars, groups, home = read_catalogue(Path(sys.argv[1]))
    traits = read_traits(Path(sys.argv[2]))
    write_orbits(Path(sys.argv[3]), stars, groups, traits)
    write_ziksa(Path(sys.argv[4]), stars, home, traits)
