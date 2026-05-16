# Section 12 — ClassDB Introspection

**Dependencies:** None
**Tools tested:** classdb_search, classdb_get_info
**Tests:** 4

---

**12.1** `classdb_search` — pattern=`CharacterBody`
- **Expect:** Results including CharacterBody2D and CharacterBody3D

**12.2** `classdb_get_info` — class_name=`AnimationPlayer`
- **Expect:** Properties, methods, signals for AnimationPlayer

**12.3** `classdb_search` — pattern=`Sv2*`
- **Expect:** May find Sv2Actor if class_name registered via GDScript, or empty

**12.4** `classdb_get_info` — class_name=`NonExistentClass12345`
- **Expect:** NOT_FOUND or empty response

---

## Cleanup

None.
