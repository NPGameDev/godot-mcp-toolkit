@tool
class_name MCPToolkitNotesExample
extends MCPToolkitExtension
## Example extension that adds a single note-writing tool.
##
## Registers [code]notes.write[/code], which writes a markdown note to a
## [code]res://[/code] path. This is the canonical "what a good extension looks
## like" reference: a path guard, the required-parameter check, the success and
## failure envelopes, and doc comments that surface in the editor's class
## reference. Copy it, rename the class, and adapt the handler.[br]
## [br]
## Example:
## [codeblock]
## notes.write(file_path="res://notes/todo.md", content="- ship it")
## [/codeblock]


## Registers this extension's commands with the live [param registry].
## [param server] is the MCP server node (unused here). Called once at load.
func register(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	var opts := MCPToolkitExtensionOptions.new("Write a markdown note to a res:// path") \
		.mark_scene_independent() \
		.guard_project_path("file_path") \
		.with_input_schema({
			"type": "object",
			"properties": {
				"file_path": {"type": "string", "description": "res:// path to the note (.md)"},
				"content": {"type": "string", "description": "Markdown body to write"},
			},
			"required": ["file_path", "content"],
		})
	# Not read-only: the tool writes. Scene-independent: it touches only a file path.
	registry.add("notes.write", _write, opts)


## Writes a markdown note to disk.
##
## Writes [param content] to the file at [param file_path] (a [code]res://[/code]
## path, guarded against traversal before this runs). Returns a success envelope
## with the written path, or a failure envelope on a missing parameter or an I/O
## error.
func _write(params: Dictionary) -> Dictionary:
	var missing: Variant = MCPToolkitError.require(params, ["file_path", "content"])
	if missing != null:
		return missing

	var file_path: String = params["file_path"]
	var content: String = params["content"]

	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return MCPToolkitError.fail("WRITE_FAILED",
			"could not open %s for writing" % file_path,
			"Check the folder exists — use folder.create first if needed.")

	file.store_string(content)
	file.close()

	return MCPToolkitSuccess.ok({"path": file_path, "bytes": content.length()})
