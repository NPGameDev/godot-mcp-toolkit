@tool
extends RefCounted
## Shared builder for the self-describing pagination envelope.
##
## Every paginating tool returns one learnable shape so an LLM caller can page any
## result set the same way. This centralizes the envelope — the invariant fields, the
## resume-field arithmetic, and the hint-inclusion gate — so no command handler
## hand-rolls it and the vocabulary can never drift between tools.
##
## Two axes describe a page:[br]
## [b]Invariants[/b] — [code]returned[/code] (rows in this page), [code]total_<unit>[/code]
## (the full count past any cap), and [code]has_more[/code] — stamped on every page.[br]
## [b]Resume[/b] — either a linear resume field ([code]next_offset[/code] /
## [code]next_start_line[/code]) for resumable tools, or a documented cursor-less
## navigation (narrow filters / query a region) surfaced in the [code]hint[/code].
##
## Reached as [code]Modules.Pagination[/code] from editor command handlers, and via a
## direct [code]preload[/code] alias from the runtime autoload (which cannot import the
## editor-tainted [code]Modules[/code] aggregator). This script names no editor-only
## symbols so it stays valid in an export template's parse of the runtime closure.
##
## The hint [i]wording[/i] is the caller's: each tool phrases its own resume/navigation
## sentence (kept byte-stable against its wire contract) and passes it in; this builder
## only decides whether to include it. The hint appears when [param has_more] is true or
## a clamp occurred (signalled by [code]limit_clamped[/code] in [param extras]).


## Stamps the pagination invariants onto a page dict and returns it.
##
## Adds [code]returned[/code], [code]total_<unit>[/code], and [code]has_more[/code] to
## [param page] (a dict the caller pre-shaped with its items and any echoed window
## params). When [param has_more] is true and [param resume_field] is non-empty, adds
## the resume field [param resume_field] set to [param resume_value]; a cursor-less tool
## passes an empty [param resume_field] and gets no resume field. Merges [param extras]
## verbatim (e.g. [code]limit_clamped[/code], a tool's echoed filters), then adds
## [param hint] when [param has_more] is true or [param extras] carries
## [code]limit_clamped[/code] and the hint is non-empty.
##
## [param unit] names the total the count describes (e.g. "matches", "classes",
## "bytes", "lines"). Returns [param page] itself, mutated in place, as a BARE dict —
## the caller wraps it in [MCPToolkitSuccess], merges it with context, or nests it.
## [codeblock]
## var page := Pagination.build({"nodes": rows, "offset": offset, "limit": limit},
##     "matches", total, rows.size(), offset + rows.size() < total,
##     "next_offset", offset + rows.size(),
##     "more matches remain — page with next_offset until has_more is false")
## return MCPToolkitSuccess.ok(page)
## [/codeblock]
static func build(page: Dictionary, unit: String, total: int, returned: int,
		has_more: bool, resume_field: String, resume_value: int, hint: String,
		extras: Dictionary = {}) -> Dictionary:
	page["returned"] = returned
	page["total_" + unit] = total
	page["has_more"] = has_more
	if has_more and resume_field != "":
		page[resume_field] = resume_value
	for key in extras.keys():
		page[key] = extras[key]
	if (has_more or extras.has("limit_clamped")) and not hint.is_empty():
		page["hint"] = hint
	return page


## LIST family — index-paginated pages (scene.query, classdb.search).
##
## Computes [code]returned[/code] from [param items] and [code]has_more[/code] from
## [param offset] against [param total], then stamps the invariants (and, when resumable
## and there is more, the [code]next_offset[/code] resume field) onto the caller-supplied
## [param page] via [method build]. The caller pre-shapes [param page] with its items and
## any echoed window params, so each tool keeps its own field set and order. [param unit]
## names the total (e.g. "matches", "classes"). [param hint] is the caller's composed
## resume/clamp sentence.
##
## Pass [param resumable] as false for a cursor-less LIST tool: [code]next_offset[/code]
## is suppressed and the caller's [param hint] carries the navigation guidance instead.
## Returns the bare page dict.
static func list_page(page: Dictionary, items: Array, offset: int, unit: String,
		total: int, hint: String, extras: Dictionary = {},
		resumable: bool = true) -> Dictionary:
	var returned := items.size()
	var has_more := offset + returned < total
	var resume_field := "next_offset" if resumable else ""
	return build(page, unit, total, returned, has_more, resume_field, offset + returned,
		hint, extras)


## CONTENT-byte family — byte-windowed pages (save.read).
##
## Computes [code]has_more[/code] from [param offset] and [param returned_bytes] against
## [param total_bytes], then stamps the invariants (unit "bytes") and the
## [code]next_offset[/code] byte resume field onto the caller-supplied [param page] via
## [method build]. [param returned_bytes] is the byte count in this window (which may
## differ from the content string length after decoding). The caller pre-shapes
## [param page] with its content and echoed [code]offset[/code]. [param hint] is the
## caller's composed resume sentence.
##
## Unlike [method list_page], [code]next_offset[/code] is emitted on every window (not only
## when there is more): a byte offset is always a valid resume point, so a paging caller
## can detect completion by [code]next_offset == total_bytes[/code]. Returns the bare page.
static func byte_page(page: Dictionary, offset: int, returned_bytes: int,
		total_bytes: int, hint: String, extras: Dictionary = {}) -> Dictionary:
	var next_offset := offset + returned_bytes
	var has_more := next_offset < total_bytes
	page["next_offset"] = next_offset
	return build(page, "bytes", total_bytes, returned_bytes, has_more,
		"", 0, hint, extras)


## CONTENT-line family — line-windowed pages (script.read, log readers).
##
## Computes [code]has_more[/code] as [param end_line] < [param total_lines], then stamps
## the invariants (unit "lines") and, when there is more, the [code]next_start_line[/code]
## resume field (1-based, [param end_line] + 1) onto the caller-supplied [param page] via
## [method build]. [param returned] is the line count in this window (pass explicitly — it
## need not equal [code]end_line - start_line + 1[/code] when the source clamps). The
## caller pre-shapes [param page] with its content and echoed line bounds. [param hint] is
## the caller's composed resume sentence. Returns the bare page dict.
static func line_page(page: Dictionary, end_line: int, returned: int, total_lines: int,
		hint: String, extras: Dictionary = {}) -> Dictionary:
	var has_more := end_line < total_lines
	return build(page, "lines", total_lines, returned, has_more,
		"next_start_line", end_line + 1, hint, extras)
