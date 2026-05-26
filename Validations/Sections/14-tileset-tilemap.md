# Section 14 — TileSet & TileMap

**Dependencies:** Section 2 (Sv2TileLayer exists in main.tscn)
**Tools tested:** tileset_create, tileset_setup_layers, tileset_add_source, tileset_remove_source, tileset_add_alternative, tileset_remove_alternative, tileset_edit_physics, tileset_edit_terrain, tileset_edit_navigation, tileset_edit_visuals, tileset_edit_custom_data, tilemap_set_cells, tilemap_read_cells
**Tests:** 28

---

## tileset group (structural — 6 tools)

**14.1** `tileset_create` — file_path=`res://sv2_validation/atlas_tileset.tres`, texture_path=`res://icon.svg`, tile_size=`{"x":32,"y":32}`, physics=`true`
- **Expect:** success, source_id=0, tiles_created > 0

> **REGRESSION WATCH (FIX-I, 7e63aee):** If tileset_create produces a generic
> Resource instead of a valid TileSet, type validation has regressed. Flag as **Critical**.

**14.2** `resource_load` — file_path=`res://sv2_validation/atlas_tileset.tres`
- **Expect:** TileSet with physics layer + tile collision polygons

**14.3** `tileset_setup_layers` — file_path=`res://sv2_validation/atlas_tileset.tres`, terrain_sets=[{mode:"match_corners_and_sides", terrains:["grass","dirt"]}], custom_data=[{name:"damage", type:"int"}], navigation_layers=1, occlusion_layers=1
- **Expect:** success

**14.4** `tileset_add_source` — file_path=`res://sv2_validation/atlas_tileset.tres`, texture_path=`res://icon.svg`, tile_size={x:64, y:64}
- **Expect:** success, new_source_id > 0

**14.5** `tileset_remove_source` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=<new_source_id from 14.4>
- **Expect:** success, removed_source_id matches

**14.6** `tileset_add_alternative` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, atlas_x=1, atlas_y=0, flip_h=true
- **Expect:** success

**14.7** `tileset_remove_alternative` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, atlas_x=1, atlas_y=0, alternative_id=1
- **Expect:** success, removed_alternative_id=1

**14.8** `tileset_create` guard — file_path=`res://sv2_validation/bad_ts.tres`, texture_path=`res://nonexistent_texture.png`
- **Expect:** NOT_FOUND

**14.9** `tileset_remove_source` guard — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=999
- **Expect:** NOT_FOUND

**14.10** `tileset_remove_alternative` guard — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, atlas_x=0, atlas_y=0, alternative_id=999
- **Expect:** NOT_FOUND

---

## tileset_edit group (per-tile — 5 tools)

**14.11** `tileset_edit_physics` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, physics_polygon:"none"}, {atlas_x:1, atlas_y:0, physics_polygon:[{x:-10,y:-16},{x:10,y:-16},{x:16,y:16},{x:-16,y:16}]}]
- **Expect:** success, tiles_modified=2

**14.12** `tileset_edit_terrain` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, terrain_set:0, terrain:0, terrain_peering:{center:0}}]
- **Expect:** success, tiles_modified >= 1

**14.13** `tileset_edit_navigation` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, navigation_polygon:"full"}]
- **Expect:** success, tiles_modified >= 1

**14.14** `tileset_edit_visuals` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:1, atlas_y:0, occlusion_polygon:"full", probability:0.5}]
- **Expect:** success, tiles_modified >= 1

**14.15** `tileset_edit_custom_data` — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, custom_data:{"damage":10}}]
- **Expect:** success, tiles_modified >= 1

**14.16** `tileset_edit_physics` guard (invalid coords) — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:99, atlas_y:99, physics_polygon:"full"}]
- **Expect:** success with errors[] for tile (99,99)

> **REGRESSION WATCH (FIX-2, T:98c02f3):** If non-integer layer count causes a
> crash instead of an error, the tileset_edit layer validation guard has regressed.
> Flag as **Critical**.

**14.17** `tileset_edit_physics` guard (missing file) — file_path=`res://no_such_tileset.tres`, tiles=[{atlas_x:0, atlas_y:0, physics_polygon:"full"}]
- **Expect:** NOT_FOUND

---

## tilemap group (2 tools)

**14.18** `tilemap_set_cells` — node_path=`Sv2TileLayer`, cells=[{"x":0,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** success (may warn about TileSet source mismatch if TileLayer doesn't reference the atlas)

**14.19** `tilemap_set_cells` (regions) — node_path=`Sv2TileLayer`, regions=[{"x":0,"y":0,"width":5,"height":5,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** success, cells painted

> **REGRESSION WATCH (FIX-A, 7e63aee):** If `regions` param is rejected,
> bulk-fill support has regressed. Flag as **Major**.

**14.20** `tilemap_set_cells` guard (no tileset) — Create TileMapLayer with NO tileset:
- `scene_create_node` node_type=TileMapLayer, node_name=`Sv2TileNoTS`, parent_path=`.`
- `tilemap_set_cells` node_path=`Sv2TileNoTS`, cells=[{"x":0,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** error mentioning no TileSet assigned

> **REGRESSION WATCH (FIX-J, 7e63aee):** If cells are silently placed on a
> TileMapLayer with no TileSet (corrupt state), the no-tileset guard has regressed.
> Flag as **Critical**.

**14.21** `tilemap_read_cells` — node_path=`Sv2TileLayer`
- **Expect:** success, returns array of cell data. Each cell has coords, source_id, atlas_coords fields.

**14.22** `tilemap_read_cells` round-trip — node_path=`Sv2TileLayer` (after 14.18/14.19 painted cells)
- **Expect:** success, cells array includes at least one entry with source_id=0, atlas_x=0, atlas_y=0. Confirms set_cells → read_cells round-trip.

**14.23** `tilemap_read_cells` guard (invalid node) — node_path=`NonExistentNode999`
- **Expect:** NOT_FOUND

**14.24** `tilemap_read_cells` guard (wrong class) — node_path=`Sv2Sprite` (a Sprite2D, not TileMapLayer)
- **Expect:** error (INVALID_CLASS or similar — node is not a TileMapLayer/TileMap)

**14.25** `tilemap_read_cells` guard (missing param) — (no node_path)
- **Expect:** INVALID_PARAMS, "missing node_path"

---

## Group activation

**14.26** `discover_tools` — request=`tileset`
- **Expect:** activates tileset group with 6 tools

**14.27** `discover_tools` — request=`tileset_edit`
- **Expect:** activates tileset_edit group with 5 tools

**14.28** `discover_tools` — request=`tilemap`
- **Expect:** activates tilemap group with 2 tools (NOT tileset tools)

---

## Cleanup

- `scene_delete_node` node_path=`Sv2TileNoTS`
- `resource_delete` file_path=`res://sv2_validation/atlas_tileset.tres`
- Call `discover_tools` with reset=true to deactivate all on-demand groups activated during this section
