extends Node2D

func _ready():
	# Triggers null-ref at runtime — not a parse error but an execution error.
	var n: Node = null
	n.queue_free()
