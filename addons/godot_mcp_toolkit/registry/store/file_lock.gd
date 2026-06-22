@tool
extends RefCounted
## A PID-aware, stale-recovering machine-wide file lock for serialising
## cross-process read-modify-write on a given path.
##
## acquire() writes "<pid>:<unix_ts>" to the lock path; a concurrent acquirer
## backs off (exponential, 50→1000 ms) while the lock is held and fresh. A lock
## is treated as stale — and overwritten — when its writer PID is dead or its
## timestamp is older than the staleness window, so a crashed holder never wedges
## the lock permanently. As a last resort the lock is force-written so the caller
## can always make progress.
##
## Both methods are static — no instance state; the lock path is passed in.
## Export-clean (FileAccess/OS/Time/DirAccess only) so runtime-reachable callers
## may preload it without tainting their static graph.

const _LOCK_STALE_SEC := 10
const _LOCK_BASE_RETRY_MS := 50
const _LOCK_MAX_RETRY_MS := 1000
const _LOCK_RETRIES := 10


## Returns true if the lock was acquired. On stale-lock detection the
## stale file is overwritten. Exponential backoff: 50, 100, 200, ... ms
## capped at 1000 ms per retry. PID-aware stale detection recovers
## locks from dead processes immediately.
static func acquire(lock_path: String) -> bool:
	var lp := lock_path
	var delay_ms := _LOCK_BASE_RETRY_MS
	for attempt in _LOCK_RETRIES:
		if FileAccess.file_exists(lp):
			var f := FileAccess.open(lp, FileAccess.READ)
			if f != null:
				var content := f.get_as_text().strip_edges()
				f.close()
				var parts := content.split(":")
				var lock_pid := int(parts[0]) if parts.size() >= 2 else 0
				var lock_ts := int(parts[-1])
				# PID check: if the locker is dead, treat as stale immediately.
				var pid_dead := lock_pid > 0 and not OS.is_process_running(lock_pid)
				if not pid_dead:
					var age := int(Time.get_unix_time_from_system()) - lock_ts
					if age < _LOCK_STALE_SEC:
						if attempt > 0:
							push_warning("[MCPRegistry] lock contention (attempt %d/%d, held by PID %d)" % [attempt + 1, _LOCK_RETRIES, lock_pid])
						OS.delay_msec(delay_ms)
						delay_ms = mini(delay_ms * 2, _LOCK_MAX_RETRY_MS)
						continue
				# Stale lock (age or dead PID) — fall through to overwrite.
		var f := FileAccess.open(lp, FileAccess.WRITE)
		if f == null:
			OS.delay_msec(delay_ms)
			delay_ms = mini(delay_ms * 2, _LOCK_MAX_RETRY_MS)
			continue
		f.store_string("%d:%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system())])
		f.close()
		return true
	push_warning("[MCPRegistry] failed to acquire lock after %d retries; proceeding anyway" % _LOCK_RETRIES)
	# Force-write the lock as a last resort so the caller can proceed.
	var f := FileAccess.open(lp, FileAccess.WRITE)
	if f != null:
		f.store_string("%d:%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system())])
		f.close()
	return true


static func release(lock_path: String) -> void:
	var lp := lock_path
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(lp)
