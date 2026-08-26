#!/usr/bin/env node
/**
 * Start Telnyx's stdio MCP without putting ${TELNYX_API_KEY} on argv.
 * @telnyx/mcp prefers --api-key= over env. Grok Bot leaves that placeholder
 * literal, which shadows a real TELNYX_API_KEY the host already injected.
 */
import { spawn } from "node:child_process";

function wiredKey() {
  for (const name of ["TELNYX_API_KEY", "PHONEZERO_CFG_TELNYX_API_KEY"]) {
    const raw = process.env[name];
    if (raw && !raw.startsWith("${")) return raw;
  }
  return "";
}

const key = wiredKey();
if (!key) {
  console.error(
    "PhoneZero Telnyx: API key not wired. Re-save Plugins → Configure and start a new conversation.",
  );
  process.exit(1);
}

const child = spawn("npx", ["-y", "@telnyx/mcp"], {
  stdio: "inherit",
  env: { ...process.env, TELNYX_API_KEY: key },
});

child.on("exit", (code, signal) => {
  process.exit(code ?? (signal ? 1 : 0));
});
