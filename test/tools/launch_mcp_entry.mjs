#!/usr/bin/env node
// Starts the .mcp.json server entry that print_mcp_entry.gd printed and checks
// that the server it launches answers an MCP initialize with the expected version.
//
// Usage: node test/tools/launch_mcp_entry.mjs --entry <file> --expect <version>
//
// <file> holds the print tool's output, engine lines included; the entry is the
// JSON after the MCP_ENTRY_JSON marker. The entry's env is merged over this
// process's env, and GODOT_MCP_EDITOR_PORT points at a port no editor listens on,
// so the server starts without dialling a real editor.
//
// Exit codes: 0 the server answered with <version>; 1 an assertion failed;
// 2 a usage or setup error.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

const ENTRY_MARKER = "MCP_ENTRY_JSON ";
const UNUSED_EDITOR_PORT = "6599";
const ANSWER_TIMEOUT_MS = 60_000;
// After stdin closes, a stdio server exits on its own; this bounds the wait
// before the child is killed instead.
const EXIT_GRACE_MS = 10_000;
const INITIALIZE_ID = 1;

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function setupError(message) {
  console.error(`ERROR: ${message}`);
  process.exit(2);
}

function parseArgs(argv) {
  const options = { entry: "", expect: "" };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag !== "--entry" && flag !== "--expect") {
      setupError(`unknown argument '${flag}'. Usage: --entry <file> --expect <version>`);
    }
    if (i + 1 >= argv.length) {
      setupError(`${flag} needs a value`);
    }
    options[flag.slice(2)] = argv[++i];
  }
  if (!options.entry || !options.expect) {
    setupError("both --entry <file> and --expect <version> are required");
  }
  return options;
}

function readEntry(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    setupError(`cannot read ${path}: ${error.message}`);
  }
  const line = text
    .split("\n")
    .map((raw) => raw.replace(/\r$/, ""))
    .find((raw) => raw.startsWith(ENTRY_MARKER));
  if (line === undefined) {
    setupError(`no '${ENTRY_MARKER.trim()}' line in ${path}; did the print tool run?`);
  }
  try {
    return JSON.parse(line.slice(ENTRY_MARKER.length));
  } catch (error) {
    setupError(`the entry line is not JSON: ${error.message}`);
  }
}

function assertPinned(entry, version) {
  if (typeof entry.command !== "string" || !Array.isArray(entry.args) || entry.args.length === 0) {
    fail(`the entry has no command and args: ${JSON.stringify(entry)}`);
  }
  const lastArg = String(entry.args[entry.args.length - 1]);
  if (!lastArg.endsWith(`@${version}`)) {
    fail(`the entry's last arg '${lastArg}' does not end with '@${version}'`);
  }
  console.log(`ok: the entry pins @${version}: ${entry.command} ${entry.args.join(" ")}`);
}

// Resolves with the initialize response, or rejects on exit or timeout.
function initialize(child) {
  return new Promise((resolve, reject) => {
    let buffered = "";
    const timer = setTimeout(
      () => reject(new Error(`no initialize response within ${ANSWER_TIMEOUT_MS / 1000} s`)),
      ANSWER_TIMEOUT_MS,
    );
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(new Error(`could not start the entry: ${error.message}`));
    });
    child.on("exit", (code, signal) => {
      clearTimeout(timer);
      reject(new Error(`the server exited before answering (code ${code}, signal ${signal})`));
    });
    child.stdout.on("data", (chunk) => {
      buffered += chunk.toString("utf8");
      let newline;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline).trim();
        buffered = buffered.slice(newline + 1);
        if (!line) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue; // Not a JSON-RPC frame.
        }
        if (message.id === INITIALIZE_ID) {
          clearTimeout(timer);
          resolve(message);
          return;
        }
      }
    });
    const request = {
      jsonrpc: "2.0",
      id: INITIALIZE_ID,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "launch-mcp-entry", version: "1.0.0" },
      },
    };
    child.stdin.write(`${JSON.stringify(request)}\n`);
  });
}

// Closes stdin so the server exits by itself (with cmd /c on Windows, killing the
// shell would leave the server running), then kills it if it has not.
function stop(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      child.kill();
      resolve();
    }, EXIT_GRACE_MS);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    child.stdin.end();
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const entry = readEntry(options.entry);
  assertPinned(entry, options.expect);

  const env = { ...process.env, ...(entry.env ?? {}), GODOT_MCP_EDITOR_PORT: UNUSED_EDITOR_PORT };
  const child = spawn(entry.command, entry.args, { env, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  // A server that dies early closes its stdin; the exit handler reports that.
  child.stdin.on("error", () => {});
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString("utf8");
  });

  let response;
  try {
    response = await initialize(child);
  } catch (error) {
    await stop(child);
    console.error(stderr.trimEnd());
    fail(error.message);
  }
  child.removeAllListeners("exit");
  await stop(child);

  if (response.error) {
    fail(`initialize returned an error: ${JSON.stringify(response.error)}`);
  }
  const answered = response.result?.serverInfo?.version;
  if (answered !== options.expect) {
    fail(`the server answered version '${answered}', expected '${options.expect}'`);
  }
  console.log(`ok: the server answered initialize as version ${answered}`);
}

await main();
