extends RefCounted
## Compile-probe fixture: the script the unit tests preload at the top of a
## checked script, held while later checks run.

const ANSWER := 42


static func doubled(value: int) -> int:
	return value * 2
