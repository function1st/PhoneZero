#!/usr/bin/env node
/**
 * Start the PhoneZero xAI MCP without assuming cwd is the plugin or repo root.
 * Cursor often resolves ./scripts/xai-mcp.mjs against the workspace. Grok Bot
 * uses /workspace on the shared cloud VM, which is not this repo.
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const SCRIPT = "xai-mcp.mjs";
const FETCH_URL =
  "https://raw.githubusercontent.com/function1st/PhoneZero/main/plugins/phonezero/scripts/xai-mcp.mjs";

function isRealServer(filePath) {
  try {
    const text = readFileSync(filePath, "utf8");
    return text.includes("phonezero-xai") && text.includes("ensure_collection");
  } catch {
    return false;
  }
}

function addCandidate(out, filePath) {
  if (filePath && !out.includes(filePath)) out.push(filePath);
}

function walkForServer(root, depth, out) {
  if (depth > 5 || !root || !existsSync(root)) return;
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const next = join(root, entry.name);
    if (entry.isFile() && entry.name === SCRIPT && isRealServer(next)) {
      addCandidate(out, next);
      return;
    }
    if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== ".git") {
      walkForServer(next, depth + 1, out);
    }
  }
}

export function candidatePaths() {
  const out = [];
  for (const key of ["PLUGIN_ROOT", "CURSOR_PLUGIN_ROOT", "GROK_PLUGIN_ROOT"]) {
    const root = process.env[key];
    if (root) addCandidate(out, join(root, "scripts", SCRIPT));
  }
  addCandidate(out, join(process.cwd(), "plugins", "phonezero", "scripts", SCRIPT));
  addCandidate(out, join(homedir(), ".cursor", "plugins", "local", "phonezero", "scripts", SCRIPT));
  addCandidate(out, join("/workspace", "plugins", "phonezero", "scripts", SCRIPT));
  addCandidate(out, join(process.cwd(), "scripts", SCRIPT));
  walkForServer(join(homedir(), ".cursor", "plugins"), 0, out);
  walkForServer(join(homedir(), ".grok", "plugins"), 0, out);
  walkForServer(join("/workspace", ".cursor", "plugins"), 0, out);
  return out;
}

export function resolveXaiMcpPath() {
  return candidatePaths().find((filePath) => existsSync(filePath) && isRealServer(filePath)) || "";
}

async function fetchFallback() {
  const dest = join(tmpdir(), "phonezero-xai-mcp.mjs");
  const response = await fetch(FETCH_URL);
  if (!response.ok) {
    throw new Error(
      `Cannot find ${SCRIPT} (Grok Bot /workspace is not the plugin). GitHub fetch failed: ${response.status}`,
    );
  }
  writeFileSync(dest, await response.text());
  if (!isRealServer(dest)) {
    throw new Error(`Fetched ${SCRIPT} but it is not the PhoneZero xAI MCP`);
  }
  return dest;
}

export async function resolveOrFetchXaiMcpPath() {
  return resolveXaiMcpPath() || (await fetchFallback());
}

export async function startXaiMcp() {
  const filePath = await resolveOrFetchXaiMcpPath();
  await import(pathToFileURL(filePath).href);
}

const invokedDirectly = /launch-xai-mcp\.mjs$/.test(process.argv[1] || "");
if (invokedDirectly) {
  if (process.argv.includes("--resolve-only")) {
    const found = resolveXaiMcpPath();
    if (!found) {
      process.stderr.write("xai-mcp.mjs not found locally\n");
      process.exit(1);
    }
    process.stdout.write(`${found}\n`);
  } else {
    await startXaiMcp();
  }
}
