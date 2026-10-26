extends RefCounted
## Compile-probe fixture: the script the unit tests preload from a nested inner
## class that a root constant also names, held while later checks run.

const ANSWER := 42


static func doubled(value: int) -> int:
	return value * 2
