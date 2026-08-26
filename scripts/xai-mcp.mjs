#!/usr/bin/env node
/**
 * Repo-root launcher. Cursor often resolves plugin MCP args against the
 * workspace / Git clone root, not plugins/phonezero/.
 */
import "../plugins/phonezero/scripts/xai-mcp.mjs";
