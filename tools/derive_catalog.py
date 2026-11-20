#!/usr/bin/env python3
"""Reduce the Infinity / Xalaria 0.68 catalogue to orbital parameters."""
import collections
import csv
import math
import sys
from pathlib import Path

groups = collections.defaultdict(list)
stars = {}
with Path(sys.argv[1]).open() as source:
    rows = csv.reader(source, delimiter="\t")
    assert next(rows)[:2] == ["XALARIA_CATALOG", "2"]
    for row in rows:
        if row[0] == "S":
            stars[int(row[1])] = (float(row[4]), float(row[5]))
        elif row[0] == "T":
            radius, temperature = {
                "red_giant": (4.1e10, 3400), "neutron_star": (1.3e4, 30000),
                "brown_dwarf": (7.0e7, 1700), "carbon_giant": (6.8e10, 2800),
            }[row[2]]
            system = int(row[1])
            stars[system] = (radius, temperature)
            groups[system].append((1.65e6, float(row[6]) * 1.496e11, 1.4e8, 180, 1, 0, 0, 0))
        elif row[0] == "W" and row[5] == "-1":
            ring_width = max(0, float(row[23]) - float(row[22]))
            groups[int(row[1])].append((
                float(row[6]), float(row[7]), float(row[8]), float(row[11]),
                int(row[12]), float(row[20]), ring_width,
                float(row[24]) if ring_width and row[24] != "-" else 0,
            ))

with Path(sys.argv[2]).open("w") as target:
    target.write("PELAGIC 1\n")
    for system, (radius, temperature) in sorted(stars.items()):
        worlds = sorted(groups[system], key=lambda world: world[1])
        worlds = sorted(sorted(worlds, key=lambda world: world[0] * (1 + min(world[6], 2)),
                                reverse=True)[:3], key=lambda world: world[1])
        target.write(f"{system} {math.log10(radius):.4f} {temperature:.2f} {len(worlds)}")
        for radius, orbit, period, temperature, material, clouds, rings, tilt in worlds:
            target.write(f" {math.log10(radius):.4f} {math.log10(orbit):.4f} "
                         f"{math.log10(max(period, 1)):.4f} {temperature:.3f} "
                         f"{material} {clouds:.3f} {rings:.3f} {tilt:.2f}")
        target.write("\n")
