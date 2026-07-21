# Parallel sessions (multi-agent concurrency)

Multiple agents can connect to the same Godot editor at once. Two systems
prevent races automatically — you don't need to do anything special, but
understanding the behaviour helps you work faster. Under contention responses
get **slower, not broken**.

## What happens behind the scenes

- **Mutation lock** — only one mutation executes at a time. If yours is queued,
  you see slightly longer response times, not errors.
- **Scene lease** — one agent at a time "owns" the active editor tab. If you are
  working on a different scene than the current tab holder, your scene commands
  queue until the tab becomes available (up to ~8 seconds before a steal
  occurs).

## The precise routing rule

Requests are ordered by three layers, in this order:

1. **Scene-lease routing happens first.** A tab-dependent command — *including a
   read* — that targets a scene which is not the active tab queues for the lease
   before anything else.
2. **Read-only commands bypass both locks.** Reads that do not depend on the
   active tab run immediately.
3. **Mutations serialize one-at-a-time (FIFO).** Two mutations never overlap;
   they run in arrival order.

So a read that targets a *non-active* scene still waits for the lease, while a
read that does not is free.

## How to tell you are contended

When you call `scene_open` and another session holds the active tab, the
response includes a hint such as:

> "Note: another session is currently editing res://forest.tscn..."

That is your signal to reorganise work order — do tab-independent work first.
Slow responses under multi-session load are contention, not failure.

## Tab-independent work (no waiting)

These execute immediately regardless of scene contention:

- Reading and writing scripts
- Managing files and folders
- Querying and setting project settings
- Managing autoloads
- Reading console output

## Tab-dependent work (may queue)

These need the active tab and may wait under contention:

- Creating, deleting, or modifying nodes in a scene
- Reading scene trees or node properties
- Saving scenes

## Best practices

1. **Check before creating.** Read existing files/scenes before creating new
   ones — another agent may have already made what you need. Survey with
   `scene_get_tree` and `script_read`.
2. **Use canonical paths.** Put scripts in `scripts/`, scenes in `scenes/`.
   Don't create files at the project root when a subdirectory exists — parallel
   agents that don't coordinate will create duplicates.
3. **Front-load tab-independent work.** Write scripts, set up autoloads, and
   configure project settings before creating scene nodes. This minimises your
   contention window.
4. **Batch properties.** Use `node_set_property` batch mode to set many
   properties in one call. Each tool call is one contention point, so fewer
   calls means less waiting.
5. **Don't fight the lease.** If your commands are taking many seconds, that is
   the lease system working. Switch to tab-independent tasks and come back to
   scene work later.
