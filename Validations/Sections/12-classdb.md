# Section 12 — ClassDB Introspection

**Dependencies:** None
**Tools tested:** classdb_search, classdb_get_info
**Tests:** 7

---

**12.1** `classdb_search` — pattern=`CharacterBody`
- **Expect:** Results including CharacterBody2D and CharacterBody3D

**12.2** `classdb_get_info` — class_name=`AnimationPlayer`
- **Expect:** Properties, methods, signals for AnimationPlayer

**12.3** `classdb_search` — pattern=`Sv2*`
- **Expect:** May find Sv2Actor if class_name registered via GDScript, or empty

**12.4** `classdb_get_info` — class_name=`NonExistentClass12345`
- **Expect:** NOT_FOUND or empty response

## Offset Pagination (41l — W1 Lane 2)

**12.5** `classdb_get_info` — class_name=`Node2D`, offset=0
- **Expect:** success, response includes `properties_total`, `methods_total`, `signals_total`, `constants_total` fields (integer counts). Properties/methods arrays are the first page (limited by internal cap).

**12.6** `classdb_get_info` — class_name=`Node2D`, offset=20
- **Expect:** success, properties array starts from item 21 (0-indexed offset=20). Totals unchanged from 12.5. If truncated, hint suggests next offset value.

**12.7** `classdb_search` — pattern=`Control`, offset=5
- **Expect:** success, `total` field shows full match count, results array starts from 6th match. If total > results.size() + offset, hint suggests next offset.

---

## Console error check

Call `editor_get_console` and scan output since section start for `UndoRedo history mismatch`. Guard tests produce intentional error logs (e.g., `Failed loading resource`) — ignore those.
- **FAIL** if any `UndoRedo history mismatch` line appears.
- **PASS** otherwise.

## Cleanup

None.
