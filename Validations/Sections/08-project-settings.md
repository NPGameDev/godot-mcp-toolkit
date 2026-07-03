# Section 8 — Project Settings & Autoloads

**Dependencies:** Section 1 (actor.gd exists for autoload test)
**Tools tested:** project_get_settings, project_set_setting, autoload_manage, layer_names_get, layer_names_set
**Tests:** 12

---

**8.1** `project_get_settings` — (no filter)
- **Expect:** Dictionary of project settings

**8.2** `project_set_setting` — setting=`application/config/name`, value=`"Sv2Validation"`
- **Expect:** success, previous_value captured

**8.3** `project_get_settings` — prefix=`application/config/`
- **Expect:** includes name="Sv2Validation"

**8.4** `project_set_setting` (autoload key guard) — setting=`autoload/SomeAutoload`, value=`"*res://fake.gd"`
- **Expect:** INVALID_PARAMS error with hint to use autoload_manage instead (bypasses editor autoload cache)

> **REGRESSION WATCH (23d69f9):** If setting autoload keys via project_set_setting
> succeeds silently without guard/hint, the autoload bypass protection has regressed.
> Flag as **Major**.

**8.5** `autoload_manage` (list) — action=`list`
- **Expect:** success, current autoload list

**8.6** `autoload_manage` (register) — action=`register`, name=`Sv2Autoload`, script_path=`res://sv2_validation/actor.gd`
- **Expect:** success

> **REGRESSION WATCH (FIX-D, 7e63aee):** After register, the autoload should be
> immediately available in the editor (EditorPlugin.add_autoload_singleton called
> internally). If a manual editor_refresh is required for the autoload to appear,
> FIX-D has regressed. Flag as **Major**.

**8.7** `autoload_manage` (list verify) — action=`list`
- **Expect:** includes Sv2Autoload with enabled=true
- **Note (4.7+):** `script_path` may surface as `uid://…` rather than `res://sv2_validation/actor.gd` (Godot 4.7's UID-preference). Functionality is unaffected — this is a Godot-version display detail, not a regression.

**8.8** `autoload_manage` (unregister) — action=`unregister`, name=`Sv2Autoload`
- **Expect:** success

**8.9** `layer_names_set` — category=`2d_physics`, layers=`{"1":"Ground","2":"Player","5":"Enemies"}`
- **Expect:** success, layers_set=3
- **Note:** the tool name is `layer_names_set`, not `project_set_layer_names`.

**8.10** `layer_names_get` — category=`2d_physics`
- **Expect:** layers {1:"Ground", 2:"Player", 5:"Enemies"}
- **Note:** the tool name is `layer_names_get`, not `project_get_layer_names`.

**8.11** `layer_names_set` guard — category=`invalid_category`
- **Expect:** INVALID_PARAMS

**8.12** `layer_names_set` (restore) — category=`2d_physics`, layers=`{"1":"","2":"","5":""}`
- **Expect:** success (clears names)

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `project_set_setting` — restore original project name from Section 0
