# Section 12 — ClassDB Introspection

**Dependencies:** None
**Tools tested:** classdb_search, classdb_get_info
**Tests:** 11

---

**12.1** `classdb_search` — pattern=`CharacterBody`
- **Expect:** Results including CharacterBody2D and CharacterBody3D

**12.2** `classdb_get_info` — class_name=`AnimationPlayer`
- **Expect:** Properties, methods, signals for AnimationPlayer

**12.3** `classdb_search` — pattern=`Sv2*`
- **Expect:** May find Sv2Actor if class_name registered via GDScript, or empty

**12.4** `classdb_get_info` — class_name=`NonExistentClass12345`
- **Expect:** NOT_FOUND or empty response

## Offset Pagination (41l — W1 Lane 2; ledger #20 rename)

> **REGRESSION WATCH (ledger #20):** `classdb_search` / `classdb_get_info` emit the
> uniform envelope — `has_more` (was `truncated`), `returned` (was `count`), always-present
> `total_<unit>`, and `next_offset`+`hint` only while `has_more`. If a response still carries
> `truncated` or a returned-size `count`, the pagination rename has regressed. Flag as **Major**.

**12.5** `classdb_get_info` — class_name=`Node2D`, offset=0
- **Expect:** success, response includes `total_properties`, `total_methods`, `total_signals`, `total_constants` fields (integer counts) + `has_more` (always present). Properties/methods arrays are the first page (limited by internal cap).

**12.6** `classdb_get_info` — class_name=`Node2D`, offset=20
- **Expect:** success, properties array starts from item 21 (0-indexed offset=20). Totals unchanged from 12.5. `has_more` always present; a single-section over-cap page adds `next_offset` + a hint to page with offset.

**12.7** `classdb_search` — pattern=`Control`, offset=5
- **Expect:** success, `total_classes` field shows full match count, results array starts from 6th match. `has_more` always present; when `has_more` the response adds `next_offset` + a hint to page with offset.

### Caller `limit` param (ledger #20, D11)

`classdb_search` and `classdb_get_info` accept a caller `limit` (default 200 = behavior-preserving).
A `limit` above the 200 max **clamps** to 200 and discloses `limit_clamped`; a `limit` < 1 is
**rejected** (INVALID_PARAMS). `get_info` applies the limit **per section**.

**12.8** `classdb_search` — base_class=`Object`, instantiable_only=false, limit=10
- **Expect:** success; `returned`=10 (page shrinks to the limit), `has_more`=true (total > 10), NO `limit_clamped` (a sub-max limit is honored, not clamped).

**12.9** `classdb_search` — base_class=`Object`, instantiable_only=false, limit=500
- **Expect:** success; `returned`=200 (clamped to the 200 max), `limit_clamped`=true, and the `hint` carries a clamp clause.

**12.10** `classdb_search` guard — base_class=`Object`, instantiable_only=false, limit=0
- **Expect:** INVALID_PARAMS (a limit < 1 is rejected, not clamped up).

**12.11** `classdb_get_info` — class_name=`Control`, include_inherited=true, sections=[`methods`], limit=3
- **Expect:** success; the methods section is capped to 3 entries, so `has_more`=true with `next_offset`=3 (per-section limit boundary). A `limit`=500 here would instead set `limit_clamped`=true; a `limit`=0 → INVALID_PARAMS.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

None.
