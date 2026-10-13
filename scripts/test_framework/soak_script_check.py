#!/usr/bin/env python3
"""Soak script_check on a loaded @tool script with static data, against one running editor.

What it measures
    script_check compiles a copy of the checked file, a probe, so it can report
    errors without reloading the script the editor has loaded. On Godot 4.6+,
    for a script the editor has loaded and compiled, the probe compiles under
    the file's own path and keeps its class_name (toolkit issue #16, PR #17);
    otherwise it compiles under a synthetic path with the class_name
    declaration stripped. This script drives script_check through the MCP
    server against one editor and checks that the probes leave the editor's
    state alone. The fixture is a @tool script with static data and no
    @static_unload, in the one-line form "class_name X extends Y", with a
    method that passes self to a parameter typed as its own class; a scene
    with a script that uses it is open while the soak runs.

    1. Static init, the decisive step, runs first. The engine keeps a compiled
       script with static data and no @static_unload in its static-script
       cache. Saving a base script reloads the loaded scripts that have a path
       and extend it, which reruns a @tool script's _static_init(); each
       _static_init() of the fixture logs the script object that ran it. The
       engine sorts those scripts in an order that relates a base only to its
       own subclasses, so a save reaches a given subclass or not depending on
       every loaded script: between saves the step loads one more unrelated
       script with a path, which changes that order. The base is saved before
       any probe (the control: does a save reach the loaded script here?), then
       after one script_check. The step fails if the probe's object reruns
       _static_init() or the editor logs an error; it passes if the probe is
       not left loaded under the file's path, where no reload can reach it;
       otherwise it is inconclusive (no save reached the probe).
    2. The soak: --loops script_check calls on the fixture, with a script_write
       of the fixture after every --write-every calls (a changed source, which
       drops the engine's cached parser for the file). Every call must report
       the script valid, with no diagnostics.
    3. After the loop: the scene's script still gets the class the editor
       registered, and its static state; a script compiled now resolves the
       class name to that class; the static-init check again, on the loop's
       last probe; no editor error since step 1; lsp_diagnostics reports no
       error in the fixture. For information only: how many of the run's probe
       objects are still alive, and the object, resource and static-memory
       deltas over the loop, per probe.

    Run it on Godot 4.6+ against a toolkit with the own-path probe: elsewhere
    the self-typed method fails script_check by design.

Usage
    python soak_script_check.py --project <project dir> --port <editor MCP port>
        [--loops 200] [--write-every 50] [--save-attempts 8]
        [--server <godot-mcp-server dist/index.js>] [--node node] [--lsp-port <port>]

    The editor must have --project open, with the toolkit plugin enabled, and
    listen on --port (the port it logs as "listening on 127.0.0.1:<port>").
    The script writes its fixtures to <project>/soak_script_check_tmp/ and
    removes them at the end. Run one soak per editor at a time.

Exit codes: 0 every check passed, 1 a check failed, 2 setup error,
3 inconclusive (no check failed, but a static-init check could not reach the probe).
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

TMP_DIR_NAME = "soak_script_check_tmp"
RES_DIR = "res://" + TMP_DIR_NAME
BASE = RES_DIR + "/soak_base.gd"
TARGET = RES_DIR + "/soak_target.gd"
CHECKER = RES_DIR + "/soak_checker.gd"
DEPENDENT = RES_DIR + "/soak_dependent.gd"
SCENE = RES_DIR + "/soak_scene.tscn"
# node_call_method resolves this path from the root of the open scene.
DRIVER = "Driver"

# The sibling server checkout: <parent>/godot-mcp-toolkit*/scripts/test_framework/ -> <parent>/godot-mcp-server/.
DEFAULT_SERVER = Path(__file__).resolve().parents[3] / "godot-mcp-server" / "dist" / "index.js"

BASE_SOURCE = """\
@tool
class_name SoakCheckBase
extends Node
"""

# A static-init log entry is the id of the script object that ran _static_init(),
# as a string: an id near 2**63 does not survive the server's JSON numbers.
TARGET_SOURCE = """\
@tool
class_name SoakCheckTarget extends SoakCheckBase

const LOG_KEY := "soak_script_check_static_inits"

static var calls := 0


static func _static_init() -> void:
\t# A lambda reports the script object it was compiled in: the loaded script or a probe.
\tvar marker := func() -> void: pass
\tvar entries: Array = Engine.get_meta(LOG_KEY, [])
\tentries.append(str(marker.get_object_id()))
\tEngine.set_meta(LOG_KEY, entries)


static func bump() -> int:
\tcalls += 1
\treturn calls


func take(_other: SoakCheckTarget) -> void:
\tpass


func pass_self() -> void:
\ttake(self)
"""

# Appended on every other script_write, so each write changes the source.
REWRITE_LINE = "# soak rewrite\n"

CHECKER_SOURCE = """\
@tool
extends RefCounted

const TARGET := "@TARGET@"


static func same() -> bool:
\treturn load(TARGET) == SoakCheckTarget
""".replace("@TARGET@", TARGET)

DEPENDENT_SOURCE = """\
@tool
extends Node

const TARGET := "@TARGET@"
const BASE := "@BASE@"
const CHECKER := "@CHECKER@"
const LOG_KEY := "soak_script_check_static_inits"

var _pads: Array[GDScript] = []


func engine_version() -> Dictionary:
\treturn Engine.get_version_info()


func static_init_log() -> Array:
\treturn Engine.get_meta(LOG_KEY, [])


func target_id() -> String:
\treturn str(load(TARGET).get_instance_id())


func check() -> Dictionary:
\tvar target := SoakCheckTarget.new()
\ttarget.pass_self()
\ttarget.free()
\treturn {"same_class": load(TARGET) == SoakCheckTarget, "bump": SoakCheckTarget.bump()}


func save_base() -> int:
\treturn ResourceSaver.save(load(BASE))


func checker_same() -> bool:
\tvar checker: GDScript = load(CHECKER)
\tif checker.reload() != OK:
\t\treturn false
\treturn bool(checker.call("same"))


func metrics() -> Dictionary:
\treturn {
\t\t"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
\t\t"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
\t\t"static_memory": Performance.get_monitor(Performance.MEMORY_STATIC),
\t}


func probe_state(id_text: String) -> Dictionary:
\tvar id := int(id_text)
\tif not is_instance_id_valid(id):
\t\treturn {"alive": false}
\tvar probe := instance_from_id(id) as GDScript
\tif probe == null:
\t\treturn {"alive": true, "script": false}
\treturn {
\t\t"alive": true,
\t\t"path": probe.resource_path,
\t\t"extends_base": probe.get_base_script() == load(BASE),
\t\t"is_loaded_script": probe == load(TARGET),
\t}


func alive_count(ids: Array) -> int:
\tvar alive := 0
\tfor id_text in ids:
\t\tif is_instance_id_valid(int(id_text)):
\t\t\talive += 1
\treturn alive


# The engine sorts the scripts it reloads with an order that only relates a base
# to its own subclasses, so whether a base reloads before its subclasses depends
# on where every loaded script sits. One more loaded script with a path changes
# that, which gives the next save another order.
func add_pad() -> int:
\tvar pad := GDScript.new()
\tpad.source_code = "extends RefCounted\\n"
\tpad.resource_path = "%s/soak_pad_%d.gd" % [TARGET.get_base_dir(), _pads.size()]
\tpad.reload()
\t_pads.append(pad)
\treturn _pads.size()


func cleanup() -> void:
\t_pads.clear()
\tEngine.remove_meta(LOG_KEY)
""".replace("@TARGET@", TARGET).replace("@BASE@", BASE).replace("@CHECKER@", CHECKER)

# Neither the root nor its first child has a script: with the editor setting
# text_editor/behavior/files/open_dominant_script_on_scene_change on, opening
# the scene opens the script of the first of those two that has one, and an
# open script blocks deleting the fixtures.
SCENE_SOURCE = """\
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="@DEPENDENT@" id="1"]

[node name="SoakRoot" type="Node"]

[node name="Spacer" type="Node" parent="."]

[node name="Driver" type="Node" parent="."]
script = ExtResource("1")
""".replace("@DEPENDENT@", DEPENDENT)

FIXTURES = {
    "soak_base.gd": BASE_SOURCE,
    "soak_target.gd": TARGET_SOURCE,
    "soak_checker.gd": CHECKER_SOURCE,
    "soak_dependent.gd": DEPENDENT_SOURCE,
    "soak_scene.tscn": SCENE_SOURCE,
}

# Tools outside the server's eager set, and the groups that activate them.
GROUPS = ["editor_advanced", "cleanup", "lsp_code_analysis"]
GROUP_TOOLS = ["editor_refresh", "editor_wait_for_idle", "scene_close", "folder_delete", "lsp_diagnostics"]


class SoakAbort(Exception):
    """A failure that leaves nothing further to check: the script restores and exits."""


def short(value: object, limit: int = 600) -> str:
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    return text if len(text) <= limit else text[:limit] + "..."


class McpClient:
    """A minimal MCP client over the server's stdio: newline-delimited JSON-RPC."""

    def __init__(self, node: str, server: str, env: dict[str, str]):
        self._proc = subprocess.Popen(
            [node, server],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        self._messages: queue.Queue = queue.Queue()
        self.stderr_tail: collections.deque = collections.deque(maxlen=40)
        self._next_id = 0
        self._exited = False
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        for raw in self._proc.stdout:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                self._messages.put(json.loads(line))
            except ValueError:
                self.stderr_tail.append("[stdout, not JSON] " + line)
        self._messages.put(None)

    def _read_stderr(self) -> None:
        # Drained continuously so a chatty server never blocks on a full pipe.
        for raw in self._proc.stderr:
            self.stderr_tail.append(raw.decode("utf-8", "replace").rstrip())

    def _send(self, message: dict) -> None:
        try:
            self._proc.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self._proc.stdin.flush()
        except OSError as error:
            raise SoakAbort(f"the MCP server stopped reading its input: {error}") from error

    def notify(self, method: str, params: dict | None = None) -> None:
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._send(message)

    def request(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        if self._exited:
            raise SoakAbort("the MCP server exited")
        self._next_id += 1
        request_id = self._next_id
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SoakAbort(f"{method}: no response within {timeout:.0f} s")
            try:
                message = self._messages.get(timeout=remaining)
            except queue.Empty:
                continue
            if message is None:
                self._exited = True
                raise SoakAbort("the MCP server exited")
            if "method" in message and "id" in message:
                # A request from the server (a ping): answer it and keep waiting.
                self._send({"jsonrpc": "2.0", "id": message["id"], "result": {}})
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise SoakAbort(f"{method}: {short(message['error'])}")
            return message.get("result", {})

    def call_tool(self, name: str, arguments: dict, timeout: float = 60.0) -> tuple[bool, object]:
        """Returns (succeeded, payload): the tool's JSON text parsed, or the raw text."""
        result = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        text = ""
        for block in result.get("content", []):
            if block.get("type") == "text":
                text = block.get("text", "")
                break
        try:
            payload: object = json.loads(text)
        except ValueError:
            payload = text
        return not result.get("isError", False), payload

    def close(self) -> None:
        try:
            self._proc.stdin.close()
        except OSError:
            pass
        try:
            self._proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait()


class Soak:
    """The editor-side calls the soak makes, through one MCP client."""

    def __init__(self, client: McpClient):
        self.client = client

    def tool(self, name: str, arguments: dict | None = None, timeout: float = 60.0) -> tuple[bool, object]:
        return self.client.call_tool(name, arguments or {}, timeout)

    def root(self, method: str, *args: object) -> object:
        """Calls a method of the fixture scene's script and returns its result."""
        ok, payload = self.tool(
            "node_call_method", {"node_path": DRIVER, "method_name": method, "args": list(args)}
        )
        if not ok or not isinstance(payload, dict) or "result" not in payload:
            raise SoakAbort(f"node_call_method {method}: {short(payload)}")
        return payload["result"]

    def static_init_log(self) -> list[str]:
        return [str(entry) for entry in self.root("static_init_log")]

    def settled_log(self, quiet: float = 2.0, timeout: float = 20.0) -> list[str]:
        """The static-init log once it has stopped growing for `quiet` seconds."""
        log = self.static_init_log()
        stable_since = time.monotonic()
        deadline = stable_since + timeout
        while time.monotonic() < deadline:
            time.sleep(0.25)
            current = self.static_init_log()
            if len(current) != len(log):
                log = current
                stable_since = time.monotonic()
            elif time.monotonic() - stable_since >= quiet:
                break
        return log

    def save_base(self) -> list[str]:
        """Saves the base script and returns the static-init log entries the save added."""
        before = self.settled_log()
        error = self.root("save_base")
        if error != 0:
            raise SoakAbort(f"ResourceSaver.save on {BASE} returned error {error}")
        return self.settled_log()[len(before):]

    def error_cursor(self) -> int:
        ok, payload = self.tool("editor_get_console", {"level_filter": "error", "limit": 1})
        if not ok or not isinstance(payload, dict):
            raise SoakAbort(f"editor_get_console: {short(payload)}")
        return int(payload.get("next_id", -1))

    def errors_since(self, cursor: int) -> tuple[int, str]:
        ok, payload = self.tool(
            "editor_get_console", {"level_filter": "error", "since_id": cursor, "limit": 100}
        )
        if not ok or not isinstance(payload, dict):
            raise SoakAbort(f"editor_get_console: {short(payload)}")
        return int(payload.get("returned", 0)), str(payload.get("entries", ""))


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []

    def add(self, status: str, name: str, detail: str) -> None:
        print(f"[{status}] {name}: {detail}", flush=True)
        self.rows.append((status, name, detail))

    def with_status(self, wanted: str) -> list[str]:
        return [name for status, name, _ in self.rows if status == wanted]


def tally(entries: list[str], target_id: str) -> str:
    counts = collections.Counter(entries)
    parts = [f"loaded script {counts.pop(target_id, 0)}x"]
    parts += [f"object {object_id} {count}x" for object_id, count in counts.items()]
    return f"{len(entries)} run(s): " + ", ".join(parts)


def setup(soak: Soak, project: Path) -> tuple[dict, str, set[str]]:
    """Writes the fixtures, opens the scene; returns (version info, loaded target id, tool names)."""
    soak.client.request(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "soak_script_check", "version": "1"},
        },
    )
    soak.client.notify("notifications/initialized")
    ok, payload = soak.tool("discover_tools", {"request": GROUPS})
    if not ok:
        raise SoakAbort(f"discover_tools: {short(payload)}")
    tools = {tool["name"] for tool in soak.client.request("tools/list", {}).get("tools", [])}
    missing = [name for name in GROUP_TOOLS if name not in tools]
    if missing:
        print(f"NOTE: tools not listed after discover_tools: {', '.join(missing)}", flush=True)

    tmp_dir = project / TMP_DIR_NAME
    tmp_dir.mkdir()
    for name, source in FIXTURES.items():
        # Written to disk rather than through script_write: a script_write
        # would run script_check's probe on the fixture before the control save.
        (tmp_dir / name).write_text(source, encoding="utf-8", newline="\n")
    ok, payload = soak.tool("editor_refresh", {}, timeout=120.0)
    if not ok:
        raise SoakAbort(f"editor_refresh: {short(payload)}")
    soak.tool("editor_wait_for_idle", {"timeout_ms": 30000}, timeout=60.0)

    deadline = time.monotonic() + 30.0
    while True:
        ok, payload = soak.tool("scene_open", {"file_path": SCENE})
        if ok:
            break
        if time.monotonic() > deadline:
            raise SoakAbort(f"scene_open {SCENE}: {short(payload)}")
        time.sleep(1.0)
    deadline = time.monotonic() + 30.0
    while True:
        try:
            version = soak.root("engine_version")
            break
        except SoakAbort:
            if time.monotonic() > deadline:
                raise
            time.sleep(1.0)
    if not isinstance(version, dict):
        raise SoakAbort(f"engine_version: {short(version)}")

    target_id = str(soak.root("target_id"))
    log = soak.settled_log()
    if target_id not in log:
        count, text = soak.errors_since(-1)
        raise SoakAbort(
            f"the fixture {TARGET} never ran _static_init() (log {log}); "
            f"{count} editor error(s): {short(text, 2000)}"
        )
    return version, target_id, tools


def check_dependent(soak: Soak, report: Report, name: str, expected_bump: int) -> None:
    result = soak.root("check")
    good = isinstance(result, dict) and result.get("same_class") is True and result.get("bump") == expected_bump
    report.add(
        "PASS" if good else "FAIL",
        name,
        f"{short(result)} (expected same_class true, bump {expected_bump})",
    )


def save_trials(soak: Soak, target_id: str, probe_ids: list[str], attempts: int) -> list[tuple[int, int, str]]:
    """Saves the base up to `attempts` times, a pad script added between saves.

    Stops at the first save that reruns a probe's _static_init(), or, with no
    probe, at the first save that reruns the loaded script's. Returns one
    (loaded-script reruns, probe reruns, tally) per save.
    """
    trials: list[tuple[int, int, str]] = []
    for attempt in range(attempts):
        if attempt:
            soak.root("add_pad")
        added = soak.save_base()
        target_runs = added.count(target_id)
        probe_runs = sum(added.count(probe_id) for probe_id in probe_ids)
        trials.append((target_runs, probe_runs, tally(added, target_id)))
        print(f"  save {attempt + 1}: {tally(added, target_id)}", flush=True)
        if probe_runs or (not probe_ids and target_runs):
            break
    return trials


def judge_probe_reload(
    soak: Soak, report: Report, name: str, target_id: str, probe_ids: list[str], attempts: int
) -> None:
    """Reports whether saving the base script reran a kept probe's _static_init()."""
    states = {probe_id: soak.root("probe_state", probe_id) for probe_id in probe_ids}
    report.add("INFO", f"{name}, probe state", short(states, 1000))
    candidates = [
        probe_id
        for probe_id, state in states.items()
        if isinstance(state, dict) and state.get("alive") and state.get("path")
    ]
    trials = save_trials(soak, target_id, probe_ids, attempts)
    probe_runs = sum(probe for _, probe, _ in trials)
    target_saves = sum(1 for target, _, _ in trials if target)
    summary = (
        f"{len(trials)} base save(s); the loaded script reran _static_init() on {target_saves}, "
        f"probe object(s) {probe_ids} reran it {probe_runs} time(s)"
    )
    if probe_runs:
        report.add("FAIL", name, f"a probe script_check compiled ran _static_init() again: {summary}")
    elif not candidates:
        report.add("PASS", name, f"no probe stays loaded under the file's path, so no reload reaches one; {summary}")
    else:
        report.add(
            "INCONCLUSIVE",
            name,
            f"probe(s) {candidates} stay loaded under the file's path, where a reload of the base can reach "
            f"them, but no save here did: {summary}",
        )


def static_init_step(soak: Soak, report: Report, target_id: str, error_cursor: int, attempts: int) -> None:
    """The decisive step: does a kept own-path probe run _static_init() when its base is saved?"""
    control = save_trials(soak, target_id, [], attempts)
    report.add(
        "INFO",
        "static init, control saves (no probe yet)",
        f"the loaded script reran _static_init() on {sum(1 for target, _, _ in control if target)} "
        f"of {len(control)} save(s)",
    )

    before = soak.settled_log()
    ok, payload = soak.tool("script_check", {"file_path": TARGET})
    after = soak.settled_log(quiet=1.0)
    probe_ids = sorted({entry for entry in after[len(before):] if entry != target_id})
    valid = ok and isinstance(payload, dict) and payload.get("valid") is True and not payload.get("diagnostics")
    report.add(
        "PASS" if valid else "FAIL",
        "static init, script_check",
        f"valid={valid}, {tally(after[len(before):], target_id)}; "
        f"probe object(s) {probe_ids or 'none'}; response {short(payload, 300)}",
    )
    if probe_ids:
        judge_probe_reload(soak, report, "static init", target_id, probe_ids, attempts)
    else:
        report.add(
            "FAIL", "static init", "script_check's probe never ran _static_init(), so the step proves nothing"
        )
    count, text = soak.errors_since(error_cursor)
    report.add(
        "FAIL" if count else "PASS",
        "static init, editor errors",
        f"{count} new error(s) over the two saves and the probe" + (f": {short(text, 2000)}" if count else ""),
    )


def soak_loop(soak: Soak, report: Report, loops: int, write_every: int) -> int:
    """Returns the number of probes the loop made (checks plus writes)."""
    metrics_before = soak.root("metrics")
    check_failures: list[str] = []
    write_failures: list[str] = []
    probes = 0
    writes = 0
    started = time.monotonic()
    for index in range(1, loops + 1):
        ok, payload = soak.tool("script_check", {"file_path": TARGET})
        probes += 1
        if not (ok and isinstance(payload, dict) and payload.get("valid") is True and not payload.get("diagnostics")):
            check_failures.append(f"#{index}: {short(payload, 300)}")
        if write_every and index % write_every == 0:
            writes += 1
            content = TARGET_SOURCE + REWRITE_LINE if writes % 2 == 1 else TARGET_SOURCE
            ok, payload = soak.tool("script_write", {"file_path": TARGET, "content": content})
            probes += 1
            if not (ok and isinstance(payload, dict) and payload.get("valid") is True and not payload.get("diagnostics")):
                write_failures.append(f"after #{index}: {short(payload, 300)}")
        if index % 50 == 0:
            print(f"  ... {index}/{loops} checks", flush=True)
    elapsed = time.monotonic() - started
    metrics_after = soak.root("metrics")

    report.add(
        "FAIL" if check_failures else "PASS",
        "loop, script_check",
        f"{loops - len(check_failures)}/{loops} valid in {elapsed:.1f} s"
        + (f"; first failures: {check_failures[:3]}" if check_failures else ""),
    )
    report.add(
        "FAIL" if write_failures else "PASS",
        "loop, script_write",
        f"{writes - len(write_failures)}/{writes} valid"
        + (f"; failures: {write_failures[:3]}" if write_failures else ""),
    )
    if isinstance(metrics_before, dict) and isinstance(metrics_after, dict) and probes:
        deltas = []
        for key in ("objects", "resources", "static_memory"):
            delta = float(metrics_after.get(key, 0)) - float(metrics_before.get(key, 0))
            deltas.append(f"{key} {delta:+.0f} ({delta / probes:+.2f}/probe)")
        report.add("INFO", "loop, memory", f"over {probes} probes: " + ", ".join(deltas))
    return probes


def after_loop(
    soak: Soak, report: Report, target_id: str, error_cursor: int, tools: set[str], attempts: int
) -> None:
    check_dependent(soak, report, "after the loop, scene script", expected_bump=2)
    same = soak.root("checker_same")
    report.add(
        "PASS" if same is True else "FAIL",
        "after the loop, fresh compile",
        f"a script compiled now resolves SoakCheckTarget to the loaded script: {same}",
    )

    log = soak.settled_log()
    probe_ids = sorted({entry for entry in log if entry != target_id})
    report.add(
        "INFO",
        "after the loop, probe objects alive",
        f"{soak.root('alive_count', probe_ids)} of the {len(probe_ids)} probe objects that ran _static_init()",
    )
    last_probe = next((entry for entry in reversed(log) if entry != target_id), None)
    if last_probe:
        judge_probe_reload(soak, report, "after the loop, static init", target_id, [last_probe], attempts)

    count, text = soak.errors_since(error_cursor)
    report.add(
        "FAIL" if count else "PASS",
        "editor errors since step 1",
        f"{count} new error(s)" + (f": {short(text, 2000)}" if count else ""),
    )

    if "lsp_diagnostics" not in tools:
        report.add("SKIP", "lsp_diagnostics", "the tool is not listed")
        return
    ok, payload = soak.tool("lsp_diagnostics", {"file_path": TARGET}, timeout=90.0)
    if not ok:
        if "LSP_UNAVAILABLE" in short(payload, 100000):
            report.add("SKIP", "lsp_diagnostics", f"the language server is unavailable: {short(payload, 300)}")
        else:
            report.add("FAIL", "lsp_diagnostics", short(payload, 600))
        return
    diagnostics = payload.get("diagnostics", []) if isinstance(payload, dict) else []
    errors = [d for d in diagnostics if isinstance(d, dict) and d.get("severity") == "Error"]
    report.add(
        "FAIL" if errors else "PASS",
        "lsp_diagnostics",
        f"{len(errors)} error(s), {len(diagnostics)} diagnostic(s)" + (f": {short(errors)}" if errors else ""),
    )


def restore(soak: Soak, project: Path) -> list[str]:
    """Undoes what the soak changed; returns what it could not undo."""
    problems: list[str] = []
    tmp_dir = project / TMP_DIR_NAME
    # main() refuses to start while the folder exists, so an existing one is this run's.
    if not tmp_dir.exists():
        return problems
    for name, call in (
        ("clear the static-init log", lambda: soak.root("cleanup")),
        ("close the scene", lambda: soak.tool("scene_close", {"file_path": SCENE})),
        ("delete the fixtures", lambda: soak.tool("folder_delete", {"path": RES_DIR, "recursive": True})),
    ):
        try:
            result = call()
            if isinstance(result, tuple) and not result[0]:
                problems.append(f"{name}: {short(result[1], 300)}")
        except SoakAbort as error:
            problems.append(f"{name}: {error}")
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
        problems.append(f"{tmp_dir} removed by the script, not the editor")
    try:
        soak.tool("editor_refresh", {}, timeout=120.0)
    except SoakAbort as error:
        problems.append(f"editor_refresh after the cleanup: {error}")
    return problems


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--project", required=True, help="the project directory the editor has open")
    parser.add_argument("--port", required=True, type=int, help="the editor's MCP port")
    parser.add_argument("--loops", type=int, default=200, help="script_check calls in the soak (default 200)")
    parser.add_argument(
        "--write-every", type=int, default=50, help="script_write the fixture after every N checks (default 50, 0 never)"
    )
    parser.add_argument("--server", default=str(DEFAULT_SERVER), help="godot-mcp-server's dist/index.js")
    parser.add_argument("--node", default="node", help="the Node.js binary (default node)")
    parser.add_argument("--lsp-port", type=int, help="the editor's GDScript language-server port, if not the default")
    parser.add_argument(
        "--save-attempts", type=int, default=8, help="base-script saves per static-init check (default 8)"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    project = Path(args.project).resolve()
    if not (project / "project.godot").is_file():
        print(f"SETUP ERROR: no project.godot in {project}")
        return 2
    if (project / TMP_DIR_NAME).exists():
        print(f"SETUP ERROR: {project / TMP_DIR_NAME} exists (a previous run's fixtures?); remove it first")
        return 2
    if not Path(args.server).is_file():
        print(f"SETUP ERROR: no server at {args.server}; build it or pass --server")
        return 2
    node = shutil.which(args.node)
    if node is None:
        print(f"SETUP ERROR: {args.node} not found")
        return 2

    env = dict(os.environ)
    env["GODOT_MCP_EDITOR_PORT"] = str(args.port)
    env["GODOT_MCP_PROJECT_PATH"] = str(project)
    if args.lsp_port:
        env["GODOT_MCP_LSP_PORT"] = str(args.lsp_port)

    print(f"soak_script_check: project {project}, port {args.port}, loops {args.loops}", flush=True)
    client = McpClient(node, args.server, env)
    soak = Soak(client)
    report = Report()
    version = "?"
    probes = 0
    abort = ""
    try:
        try:
            info, target_id, tools = setup(soak, project)
            version = str(info.get("string", "?"))
            print(f"editor {version}; the loaded fixture script is object {target_id}", flush=True)
            if (int(info.get("major", 0)), int(info.get("minor", 0))) < (4, 6):
                print("NOTE: before Godot 4.6 script_check strips class_name; this soak targets 4.6+", flush=True)
            check_dependent(soak, report, "before the probes, scene script", expected_bump=1)
            error_cursor = soak.error_cursor()
            static_init_step(soak, report, target_id, error_cursor, args.save_attempts)
            probes = 1 + soak_loop(soak, report, args.loops, args.write_every)
            after_loop(soak, report, target_id, error_cursor, tools, args.save_attempts)
        except SoakAbort as error:
            abort = str(error)
        except Exception as error:  # a bug in this script: still restore the project
            abort = f"{type(error).__name__}: {error}"
    finally:
        problems = restore(soak, project)
        client.close()

    for problem in problems:
        print(f"RESTORE: {problem}")
    if abort:
        print(f"SETUP ERROR: {abort}")
        print("server stderr (tail):")
        for line in client.stderr_tail:
            print(f"  {line}")
    failed = report.with_status("FAIL")
    inconclusive = report.with_status("INCONCLUSIVE")
    if abort:
        verdict = "SETUP-ERROR"
    else:
        verdict = "FAIL" if failed else ("INCONCLUSIVE" if inconclusive else "PASS")
    print(
        f"SOAK {verdict} godot={version} port={args.port} loops={args.loops} probes={probes}"
        + (f" failed=[{'; '.join(failed)}]" if failed else "")
        + (f" inconclusive=[{'; '.join(inconclusive)}]" if inconclusive else "")
    )
    return {"SETUP-ERROR": 2, "FAIL": 1, "INCONCLUSIVE": 3, "PASS": 0}[verdict]


if __name__ == "__main__":
    sys.exit(main())
