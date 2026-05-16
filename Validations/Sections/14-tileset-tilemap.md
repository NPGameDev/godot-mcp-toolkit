# Section 14 — TileSet & TileMap

**Dependencies:** Section 2 (Sv2TileLayer exists in main.tscn)
**Tools tested:** tileset_create, tileset_edit, tilemap_set_cells
**Tests:** 14

---

**14.1** `tileset_create` — file_path=`res://sv2_validation/atlas_tileset.tres`, texture_path=`res://icon.svg`, tile_size=`{"x":32,"y":32}`, physics=`true`
- **Expect:** success, source_id=0, tiles_created > 0

> **REGRESSION WATCH (FIX-I, 7e63aee):** If tileset_create produces a generic
> Resource instead of a valid TileSet, type validation has regressed. Flag as **Critical**.

**14.2** `resource_load` — file_path=`res://sv2_validation/atlas_tileset.tres`
- **Expect:** TileSet with physics layer + tile collision polygons

**14.3** `tileset_edit` (collision) — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, physics_polygon:"none"}, {atlas_x:1, atlas_y:0, physics_polygon:[{x:-10,y:-16},{x:10,y:-16},{x:16,y:16},{x:-16,y:16}]}]
- **Expect:** success, tiles_modified=2

**14.4** `tileset_edit` (terrain) — file_path=`res://sv2_validation/atlas_tileset.tres`, layers={terrain_sets:[{name:"ground", mode:"match_corners_and_sides", terrains:["grass","dirt"]}]}, tiles=[{atlas_x:0, atlas_y:0, terrain_set:0, terrain:0, terrain_peering:{center:0}}]
- **Expect:** success

**14.5** `tileset_edit` (navigation + occlusion) — file_path=`res://sv2_validation/atlas_tileset.tres`, layers={navigation_layers:1, occlusion_layers:1}, tiles=[{atlas_x:0, atlas_y:0, navigation_polygon:"full", occlusion_polygon:"full"}]
- **Expect:** success

**14.6** `tileset_edit` (custom data) — file_path=`res://sv2_validation/atlas_tileset.tres`, layers={custom_data:[{name:"damage", type:"int"}]}, tiles=[{atlas_x:0, atlas_y:0, custom_data:{"damage":10}}]
- **Expect:** success

**14.7** `tileset_edit` (animation) — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:0, atlas_y:0, animation:{frame_count:2, columns:2, frame_duration:0.5}}]
- **Expect:** success

**14.8** `tileset_edit` (alternatives) — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:1, atlas_y:0, alternative:{flip_h:true}}]
- **Expect:** success

**14.9** `tileset_edit` (add source) — file_path=`res://sv2_validation/atlas_tileset.tres`, add_source={texture_path:"res://icon.svg", tile_size:{x:64,y:64}}
- **Expect:** success, new_source_id > 0

**14.10** `tileset_edit` guard (invalid coords) — file_path=`res://sv2_validation/atlas_tileset.tres`, source_id=0, tiles=[{atlas_x:99, atlas_y:99, probability:0.5}]
- **Expect:** errors[] for tile (99,99)

> **REGRESSION WATCH (FIX-2, T:98c02f3):** If non-integer layer count causes a
> crash instead of an error, the tileset_edit layer validation guard has regressed.
> Flag as **Critical**.

**14.11** `tilemap_set_cells` — node_path=`Sv2TileLayer`, cells=[{"x":0,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** success (may warn about TileSet source mismatch if TileLayer doesn't reference the atlas)

**14.12** `tilemap_set_cells` (regions) — node_path=`Sv2TileLayer`, regions=[{"x":0,"y":0,"width":5,"height":5,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** success, cells painted

> **REGRESSION WATCH (FIX-A, 7e63aee):** If `regions` param is rejected,
> bulk-fill support has regressed. Flag as **Major**.

**14.13** `tilemap_set_cells` guard (no tileset) — Create TileMapLayer with NO tileset:
- `scene_create_node` node_type=TileMapLayer, node_name=`Sv2TileNoTS`, parent_path=`.`
- `tilemap_set_cells` node_path=`Sv2TileNoTS`, cells=[{"x":0,"y":0,"source_id":0,"atlas_x":0,"atlas_y":0}]
- **Expect:** error mentioning no TileSet assigned

> **REGRESSION WATCH (FIX-J, 7e63aee):** If cells are silently placed on a
> TileMapLayer with no TileSet (corrupt state), the no-tileset guard has regressed.
> Flag as **Critical**.

**14.14** `tileset_create` guard — file_path=`res://sv2_validation/bad_ts.tres`, texture_path=`res://nonexistent_texture.png`
- **Expect:** NOT_FOUND

---

## Cleanup

- `scene_delete_node` node_path=`Sv2TileNoTS`
- `resource_delete` file_path=`res://sv2_validation/atlas_tileset.tres`
- If `tilemap` group was activated for this section: call `discover_tools` with reset=["tilemap"] to deactivate it
