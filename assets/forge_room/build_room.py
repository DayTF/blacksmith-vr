"""Blender background exporter for the one-room forge study."""
import math
import random
from pathlib import Path

import bpy


bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, color, roughness, metallic=0.0, glow=0.0):
    result = bpy.data.materials.new(name)
    result.use_nodes = True
    surface = result.node_tree.nodes.get("Principled BSDF")
    surface.inputs["Base Color"].default_value = (*color, 1)
    surface.inputs["Roughness"].default_value = roughness
    surface.inputs["Metallic"].default_value = metallic
    if glow:
        surface.inputs["Emission"].default_value = (*color, 1)
        surface.inputs["Emission Strength"].default_value = glow
    return result


def blender_position(point):
    x, y, z = point
    return (x, -z, y)


def box(name, position, size, finish, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=blender_position(position))
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = (size[0], size[2], size[1])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(finish)
    if bevel:
        modifier = obj.modifiers.new("Bevel", 'BEVEL')
        modifier.width = bevel
        modifier.segments = 2
        modifier = obj.modifiers.new("Weighted normals", 'WEIGHTED_NORMAL')
    return obj


slate = material("Blue charcoal plaster", (0.075, 0.091, 0.107), 0.94)
mortar = material("Limestone grout", (0.13, 0.104, 0.079), 0.95)
wood = material("Smoked oak", (0.115, 0.055, 0.024), 0.8)
iron = material("Forged iron", (0.14, 0.164, 0.19), 0.38, 0.76)
rim = material("Ground steel", (0.29, 0.32, 0.35), 0.28, 0.81)
brass = material("Aged bronze", (0.39, 0.19, 0.05), 0.42, 0.72)
char = material("Soot", (0.021, 0.014, 0.009), 0.99)
ember = material("Stationary ember reference", (0.87, 0.09, 0.008), 0.72, glow=1.0)
water = material("Still quench reference", (0.035, 0.17, 0.20), 0.19, 0.42)
floor = [material("Slate tile " + str(i + 1), (shade, shade * 0.96, shade * 0.87), 0.83)
         for i, shade in enumerate((0.122, 0.145, 0.167, 0.194))]
brick = [material("Firebrick " + str(i + 1), (shade, shade * 0.54, shade * 0.36), 0.88)
         for i, shade in enumerate((0.18, 0.225, 0.28))]
randomizer = random.Random(1849)

box("Foundation", (0, -0.09, 0), (4.20, 0.16, 6.20), mortar)
paving = {finish.name: [] for finish in floor}
for row in range(10):
    for col in range(7):
        finish = randomizer.choice(floor)
        tile = box("Slate paving", (-2 + (col + 0.5) * (4 / 7), -0.017, -3 + (row + 0.5) * 0.6),
                   (4 / 7 - 0.009, 0.034, 0.591), finish, 0.006)
        for modifier in list(tile.modifiers):
            bpy.ops.object.modifier_apply(modifier=modifier.name)
        paving[finish.name].append(tile)
for finish, tiles in paving.items():
    if not tiles:
        continue
    bpy.ops.object.select_all(action='DESELECT')
    bpy.context.view_layer.objects.active = tiles[0]
    for tile in tiles:
        tile.select_set(True)
    bpy.ops.object.join()
    tiles[0].name = finish + " paving"
box("Back wall", (0, 1.5, -3.09), (4.23, 3.0, 0.18), slate)
for side in (-1, 1):
    box("Front wall", (side * 1.33, 1.5, 3.09), (1.36, 3.0, 0.18), slate)
    box("Door jamb", (side * 0.60, 1.13, 3.02), (0.12, 2.26, 0.17), wood, 0.012)
    box("Side wall", (side * 2.09, 1.5, 0), (0.18, 3.0, 6.0), slate)
    box("Skirting", (side * 1.96, 0.11, 0), (0.10, 0.22, 6.0), mortar, 0.01)
    for z in (-2.86, -0.80, 1.24, 2.88):
        box("Oak post", (side * 1.935, 1.53, z), (0.15, 3.06, 0.16), wood, 0.012)
box("Door lintel", (0, 2.58, 3.09), (1.28, 0.84, 0.18), slate)
box("Ceiling", (0, 3.05, 0), (4.2, 0.10, 6.15), wood)
for z in (-2.85, -1.5, 0, 1.5, 2.85):
    box("Ceiling beam", (0, 2.89, z), (4.0, 0.22, 0.17), wood, 0.014)

# Back forge has a brick opening, hearth, hood and flue.
box("Forge hearth", (-0.48, 0.41, -2.46), (1.56, 0.82, 0.84), mortar, 0.025)
box("Hearth cap", (-0.48, 0.82, -2.45), (1.64, 0.13, 0.94), iron, 0.024)
box("Forge rear lining", (-0.48, 1.12, -2.87), (1.42, 0.65, 0.17), char)
for row in range(4):
    for x in (-1.14, -0.96, 0.0, 0.18):
        box("Firebrick course", (x, 0.93 + row * 0.145, -2.45), (0.169, 0.132, 0.74),
            randomizer.choice(brick), 0.012)
box("Hearth hood", (-0.48, 1.55, -2.48), (1.60, 0.20, 0.95), iron, 0.065)
box("Forge flue", (-0.48, 2.20, -2.62), (0.47, 1.16, 0.44), iron, 0.035)
for index in range(12):
    box("Banked coal", (-0.77 + (index % 6) * 0.109, 0.899, -2.38 - (index // 6) * 0.106),
        (0.085, 0.042, 0.084), ember if index % 3 != 0 else char, 0.014)

# Central anvil and separate stock stand.
box("Anvil oak block", (0, 0.305, -0.18), (0.52, 0.61, 0.57), wood, 0.05)
for y in (0.075, 0.525):
    box("Block strap", (0, y, -0.18), (0.53, 0.06, 0.58), iron, 0.015)
box("Anvil foot", (0, 0.642, -0.18), (0.43, 0.075, 0.30), iron, 0.018)
box("Anvil waist", (0, 0.75, -0.18), (0.28, 0.19, 0.23), iron, 0.034)
box("Anvil working face", (0, 0.865, -0.18), (0.48, 0.07, 0.31), rim, 0.014)
horn = box("Anvil horn", (0.32, 0.84, -0.18), (0.22, 0.09, 0.18), iron, 0.039)
horn.rotation_euler.z = math.radians(6)

# Open tank with visible wall thickness and still liquid stand-in.
box("Quench tank stand", (1.39, 0.32, -1.34), (0.69, 0.64, 0.80), wood, 0.035)
box("Tank floor", (1.39, 0.65, -1.34), (0.75, 0.10, 0.86), iron, 0.035)
for x in (1.045, 1.735):
    box("Tank long wall", (x, 0.819, -1.34), (0.055, 0.28, 0.86), iron, 0.016)
for z in (-1.742, -0.938):
    box("Tank end wall", (1.39, 0.819, z), (0.66, 0.28, 0.055), iron, 0.016)
box("Tank liquid surface", (1.39, 0.868, -1.34), (0.64, 0.020, 0.758), water)
for x in (1.048, 1.732):
    box("Tank bronze top rail", (x, 0.96, -1.34), (0.07, 0.045, 0.86), brass, 0.012)

# Right-wall rack and hanging tools.
box("Tool rack backboard", (1.93, 1.54, 0.25), (0.13, 0.43, 1.15), wood, 0.022)
for idx, z in enumerate((-0.14, 0.09, 0.32, 0.55)):
    length = (0.54, 0.48, 0.61, 0.43)[idx]
    box("Forging tool grip", (1.81, 1.48 - length / 2, z), (0.045, length, 0.046), wood, 0.014)
    box("Hanging tool head", (1.80, 1.48, z), (0.09, 0.10, 0.17 if idx % 2 else 0.12), rim, 0.014)
    box("Wall peg", (1.84, 1.57, z), (0.15, 0.035, 0.035), brass, 0.005)
box("Left stock workbench", (-1.56, 0.83, 0.15), (0.63, 0.10, 1.34), wood, 0.025)
for z in (-0.37, 0.66):
    for x in (-1.77, -1.36):
        box("Stock bench leg", (x, 0.40, z), (0.11, 0.8, 0.11), wood, 0.012)
for idx in range(5):
    box("Stock blank", (-1.73 + idx * 0.076, 0.906, 0.12), (0.045, 0.052, 0.49), iron, 0.007)

output = Path(__file__).resolve().with_name("forge_room.glb")
bpy.ops.export_scene.gltf(filepath=str(output), export_format="GLB", export_apply=True)
