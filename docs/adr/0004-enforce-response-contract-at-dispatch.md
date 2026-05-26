# Enforce response contract at dispatch

All command handlers (built-in and extension) must return a `Dictionary` with a `"success"` key. The framework validates this contract in `call_command()` before passing results to the MCP client.

## Context

Handler return values were passed through `call_command()` with no validation. The documentation (`extending.md`) falsely claimed validation existed: "The extension loader validates handler return values at runtime. Malformed returns (non-Dictionary, missing success key) are normalized to the standard error envelope." This was not true — `call_command()` returned the handler result directly.

Several built-in handlers (execute.code, script read/check, signal list) returned Dictionaries without a `success` key. These worked by accident because the server-side passthrough (`obj.success !== false`) treated absent `success` as "not an error."

## Considered Options

**A. Document-only fix.** Remove the false claim from extending.md, document that handlers *should* return `success` but the framework doesn't enforce it. Zero risk of breaking existing extensions, but extensions that return malformed responses produce confusing MCP client behavior — the LLM can't distinguish "success with no success key" from "failure with no success key."

**B. Warn but pass through.** Log `push_warning` for malformed returns but still pass them to the MCP client. Gradual migration path, but warnings are invisible to extension authors testing via MCP clients (they'd need to watch the Godot console). The false claim stays false.

**C. Hard enforcement (chosen).** Validate in `call_command()`. Non-Dictionary returns and missing `success` keys produce `push_error` + an INTERNAL error response to the client. Extensions that worked by accident now fail loudly.

Option C was chosen because:

- LLMs need an unambiguous `success` signal to decide next steps. Absent `success` forces the model to guess.
- The server-side passthrough (`obj.success !== false`) masked real bugs in 4+ built-in handlers for months.
- Extensions deserve the same contract enforcement as built-in tools — the framework should catch mistakes at development time, not in production.
- Pre-1.0: no third-party extensions in the wild. This is the right time for a strict break.

## Consequences

- All handlers (built-in and extension) MUST return `{"success": true, ...}` or `{"success": false, "error": ..., "code": ...}`.
- `MCPToolkitError.fail()` guarantees the correct error shape. Extensions should use it (or the `registry.fail()` factory for C#) rather than constructing error dictionaries manually.
- Extensions that previously returned bare dictionaries without `success` will now get INTERNAL errors in the MCP response and `push_error` in the Godot console. The error message names the specific handler, making the fix obvious.
- The documentation claim is now true: the framework does validate handler returns at runtime.
- Built-in handlers fixed in this iteration: `execute.code`, `script.read` (range and full), `script.check`, `signal.list`.
