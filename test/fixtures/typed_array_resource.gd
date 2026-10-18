extends Resource
## Test double for a script resource with typed array properties, as resource.write
## creates it: the create path calls the script's new(), so the editor gives it a
## live instance, whose set() drops an untyped array on a typed array property.

@export var tags: Array[String] = []
@export var textures: Array[Texture2D] = []
