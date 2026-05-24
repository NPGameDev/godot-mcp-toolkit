extends CharacterBody2D

class_name Sv2Actor

@export var speed := 100.0
@export var label := "default"

signal hit

func get_info() -> String:
	return "Sv2Actor v1"

func _ready() -> void:
	pass
