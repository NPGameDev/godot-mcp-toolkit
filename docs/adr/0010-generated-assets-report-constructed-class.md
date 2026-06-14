# 0010 — Generated placeholder assets report their constructed class and skip import-settle

**Status:** accepted (iter 41m-sexies, 2026-06-14)

`texture_generate` and `sound_generate` write an asset whose type they know by
construction (a PNG is a `Texture2D`, a WAV is an `AudioStreamWAV`). They therefore
report that class **directly** and default `wait_for_scan_ms` to **0** — skipping
the blocking `EditorFileSystem` import-settle poll that the shared
`write_asset_with_settle` helper runs for `asset.import`. A single non-blocking
`update_file()` still fires so the FS dock catches up; the asset is usable
immediately regardless (`resource_load` imports on demand). `asset.import` is
untouched — it passes no `known_class`, because the imported type is genuinely
unknown until the editor runs the import, so it must still settle.

## Why (the trade-off)

Before this, batched generators polled `get_file_type()` until the editor imported
the freshly-written file — which, under an unfocused/throttled editor or rapid
batched writes, often never happened in-window, burning the full 5000 ms per call
and still returning `class: null` plus a spurious "did not index" warning. The
class field never feeds a later call (assignment passes the *path*; the resource
loads on demand), so its only job is to tell the LLM what it now holds. Deriving
it removes N×5 s of editor-blocking latency for free.

## The `Texture2D`-not-`CompressedTexture2D` choice (don't "fix" this)

`get_file_type()` on an imported PNG returns **`CompressedTexture2D`** (the
import-pipeline's concrete subtype). We deliberately report the base **`Texture2D`**
instead, because that is the type the LLM operates on — a generated texture is
assigned to `Sprite2D.texture` / `TextureRect.texture` / `Button.icon`, all typed
`Texture2D`; the compression detail is irrelevant to that decision. Sound reports
`AudioStreamWAV` (the concrete, actionable type, which also matches
`get_file_type`). This divergence from `get_file_type` for textures is intentional
— do not "correct" it to `CompressedTexture2D`.
