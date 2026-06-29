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
- **Expect:** success, response includes `total_properties`, `total_methods`, `total_signals`, `total_constants` fields (integer counts) + `truncated` (always present). Properties/methods arrays are the first page (limited by internal cap).

**12.6** `classdb_get_info` — class_name=`Node2D`, offset=20
- **Expect:** success, properties array starts from item 21 (0-indexed offset=20). Totals unchanged from 12.5. `truncated` always present; a single-section truncation adds `next_offset` + a hint to page with offset.

**12.7** `classdb_search` — pattern=`Control`, offset=5
- **Expect:** success, `total_classes` field shows full match count, results array starts from 6th match. `truncated` always present; when truncated the response adds `next_offset` + a hint to page with offset.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

None.
