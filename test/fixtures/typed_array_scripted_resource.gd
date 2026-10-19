extends Resource
## Test double for a script resource whose typed arrays take a script class and an
## int, as resource.write creates it: the create path calls the script's new(), so
## the resource is a live instance.

const TypedArrayElement := preload("res://test/fixtures/typed_array_element.gd")

@export var elements: Array[TypedArrayElement] = []
@export var scores: Array[int] = []
