#!/usr/bin/env node
/**
 * PhoneZero xAI MCP — Files, collections, STT, phone-numbers.
 * Configure injects XAI_API_KEY into this process only (not the agent shell).
 * Never print the key.
 */
import { Buffer } from "node:buffer";
import { writeSync } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const API = "https://api.x.ai/v1";
const PHONE_API = "https://api.x.ai/v2";
const COLLECTION_NAME = "PhoneZero bookings";
const TASK_NAME = "phonezero-task.json";
const LEGACY_BOOKING_NAME = "phonezero-booking.json";
const TEMPLATE_PREFIX = "phonezero-template-";
const BOOKING_KEYS = [
  "spoken_name",
  "restaurant",
  "party",
  "date",
  "preferred_time",
  "window",
  "alternates",
  "booking_name",
  "callback",
];
const TASK_ENVELOPE_KEYS = [
  "skill",
  "spoken_name",
  "callee",
  "callback",
  "goal",
  "opener",
  "constraints",
  "success",
  "voicemail",
  "playbook",
  "facts",
];
const HERE = dirname(fileURLToPath(import.meta.url));
const BUNDLED_SKILLS_DIR = join(HERE, "..", "skills");

const TOOLS = [
  {
    name: "get_call_config",
    description:
      "Non-secret PhoneZero call config (From). Spoken name and disclose are per-task, not Configure. Destinations are the Telnyx voice-profile whitelist, not this tool. Never returns API keys.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "ensure_collection",
    description:
      "Find-or-create the xAI collection named PhoneZero bookings. 403 + Zero Data Retention means the key's team has ZDR on.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "put_task",
    description:
      "Replace phonezero-task.json on PhoneZero bookings and wait until processed. Pass a phonezero-task object (kind phonezero-task). Does not delete phonezero-template-* files.",
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "object", description: "phonezero-task JSON object" },
      },
      required: ["task"],
      additionalProperties: false,
    },
  },
  {
    name: "put_booking",
    description:
      "Alias: wrap a kind phonezero-booking object into phonezero-task (skill book-restaurant) and upload phonezero-task.json.",
    inputSchema: {
      type: "object",
      properties: {
        booking: { type: "object", description: "phonezero-booking or phonezero-task JSON object" },
      },
      required: ["booking"],
      additionalProperties: false,
    },
  },
  {
    name: "delete_booking",
    description:
      "Remove the live brief (phonezero-task.json / legacy phonezero-booking.json) and delete that xAI file. Refuses phonezero-template-* files.",
    inputSchema: {
      type: "object",
      properties: {
        collection_id: { type: "string" },
        file_id: { type: "string" },
      },
      required: ["collection_id", "file_id"],
      additionalProperties: false,
    },
  },
  {
    name: "put_template",
    description:
      "Save a reusable call shape as phonezero-template-{slug}.json. Not deleted after a call. Do not include this-call callee/date unless freeze is true.",
    inputSchema: {
      type: "object",
      properties: {
        slug: { type: "string", description: "lowercase hyphenated id" },
        template: { type: "object", description: "phonezero-template object" },
      },
      required: ["slug", "template"],
      additionalProperties: false,
    },
  },
  {
    name: "list_templates",
    description: "List phonezero-template-*.json files in PhoneZero bookings.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_template",
    description: "Fetch one saved template by slug.",
    inputSchema: {
      type: "object",
      properties: {
        slug: { type: "string" },
      },
      required: ["slug"],
      additionalProperties: false,
    },
  },
  {
    name: "list_phone_skills",
    description:
      "Cursor-only: list bundled, ~/.phonezero/skills, and project .phonezero/skills folders (name, description, source). Skips _template, phonezero-runtime, and the deprecated phonezero stub.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_phone_skill",
    description:
      "Cursor-only: return SKILL.md, brief.schema.json, and references/voice-playbook.md for one skill name.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string" },
      },
      required: ["name"],
      additionalProperties: false,
    },
  },
  {
    name: "transcribe",
    description:
      "xAI STT (POST /v1/stt, multichannel). file_path is a local audio file already downloaded (e.g. Telnyx recording).",
    inputSchema: {
      type: "object",
      properties: {
        file_path: { type: "string" },
        language: { type: "string", default: "en" },
      },
      required: ["file_path"],
      additionalProperties: false,
    },
  },
  {
    name: "list_phone_numbers",
    description: "GET /v2/phone-numbers. Returns e164, origin, phoneNumberId, agentId.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "register_byo_number",
    description:
      "Register a Telnyx DID with xAI as byo_trunk if it is not already listed.",
    inputSchema: {
      type: "object",
      properties: {
        phone_number: { type: "string", description: "E.164 Telnyx DID" },
      },
      required: ["phone_number"],
      additionalProperties: false,
    },
  },
  {
    name: "attach_agent",
    description:
      "PATCH a byo_trunk number with agentId using protobuf fieldMask paths [agent_id]. Never send a flat {agentId}.",
    inputSchema: {
      type: "object",
      properties: {
        phone_number_id: { type: "string" },
        agent_id: { type: "string" },
      },
      required: ["phone_number_id", "agent_id"],
      additionalProperties: false,
    },
  },
];

const ENV_ALIASES = {
  XAI_API_KEY: ["XAI_API_KEY", "PHONEZERO_CFG_XAI_API_KEY"],
  PHONEZERO_FROM_NUMBER: ["PHONEZERO_FROM_NUMBER", "PHONEZERO_CFG_FROM_NUMBER"],
  PHONEZERO_AGENT_NAME: ["PHONEZERO_AGENT_NAME", "PHONEZERO_CFG_AGENT_NAME"],
  PHONEZERO_DISCLOSE_AI: ["PHONEZERO_DISCLOSE_AI", "PHONEZERO_CFG_DISCLOSE_AI"],
};

function envValue(name) {
  const keys = ENV_ALIASES[name] || [name];
  for (const key of keys) {
    const raw = process.env[key];
    if (raw && !raw.startsWith("${")) return raw;
  }
  return "";
}

function requireKey() {
  const key = envValue("XAI_API_KEY");
  if (!key) {
    throw new Error(
      "XAI_API_KEY is not set on the PhoneZero xAI MCP. Re-enter it on Plugins → Configure and start a new conversation.",
    );
  }
  return key;
}

async function xaiJson(method, url, { body, headers } = {}) {
  const key = requireKey();
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${key}`,
      Accept: "application/json",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text.slice(0, 400) };
    }
  }
  if (!res.ok) {
    const msg =
      (data && (data.error || data.message || data.detail)) || text.slice(0, 400);
    throw new Error(`xAI ${method} ${url} HTTP ${res.status}: ${msg}`);
  }
  return data;
}

async function xaiForm(url, form) {
  const key = requireKey();
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${key}` },
    body: form,
  });
  const text = await res.text();
  let data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text.slice(0, 400) };
    }
  }
  if (!res.ok) {
    const msg =
      (data && (data.error || data.message || data.detail)) || text.slice(0, 400);
    throw new Error(`xAI POST ${url} HTTP ${res.status}: ${msg}`);
  }
  return data;
}

function parseDisclose(raw) {
  if (raw === undefined || raw === "") return true;
  return !["false", "0", "no", "off"].includes(String(raw).toLowerCase());
}

function getCallConfig() {
  const fromNumber = envValue("PHONEZERO_FROM_NUMBER");
  return {
    from_number: fromNumber,
    from_last4: fromNumber.length >= 4 ? fromNumber.slice(-4) : "",
    agent_name: envValue("PHONEZERO_AGENT_NAME") || "PhoneZero",
    disclose_ai: parseDisclose(envValue("PHONEZERO_DISCLOSE_AI")),
    from_wired: Boolean(fromNumber),
    xai_key_wired: Boolean(envValue("XAI_API_KEY")),
  };
}

function collectionIdOf(item) {
  if (!item || typeof item !== "object") return "";
  return item.collection_id || item.id || "";
}

function collectionNameOf(item) {
  if (!item || typeof item !== "object") return "";
  return item.collection_name || item.name || "";
}

async function ensureCollection() {
  const listed = await xaiJson("GET", `${API}/collections`);
  const items = listed.collections || listed.data || (Array.isArray(listed) ? listed : []);
  for (const item of items) {
    if (collectionNameOf(item) === COLLECTION_NAME) {
      const id = collectionIdOf(item);
      if (id) return { collection_id: id, created: false };
    }
  }
  const created = await xaiJson("POST", `${API}/collections`, {
    body: {
      collection_name: COLLECTION_NAME,
      collection_description: "Current PhoneZero call briefs and optional templates",
      field_definitions: [
        {
          key: "kind",
          required: false,
          inject_into_chunk: true,
          unique: false,
          description: "Document kind",
        },
      ],
    },
  });
  const id = collectionIdOf(created);
  if (!id) throw new Error("create collection response missing collection_id");
  return { collection_id: id, created: true };
}

function documentNameOf(doc) {
  if (!doc || typeof doc !== "object") return "";
  return doc.name || doc.filename || doc.file_metadata?.name || "";
}

function documentFileIdOf(doc) {
  if (!doc || typeof doc !== "object") return "";
  return doc.file_id || doc.id || doc.file_metadata?.file_id || "";
}

function validateBooking(booking) {
  if (!booking || typeof booking !== "object" || booking.kind !== "phonezero-booking") {
    throw new Error("booking must be an object with kind phonezero-booking");
  }
  const missing = BOOKING_KEYS.filter((k) => booking[k] === undefined || booking[k] === "");
  if (missing.length) throw new Error(`booking missing: ${missing.join(", ")}`);
}

function wrapBooking(booking) {
  if (!booking || typeof booking !== "object") {
    throw new Error("booking must be an object");
  }
  if (booking.kind === "phonezero-task") return booking;
  validateBooking(booking);
  const party = booking.party;
  const date = booking.date;
  const preferred = booking.preferred_time;
  const name = booking.booking_name;
  const window = booking.window;
  const alts = Array.isArray(booking.alternates) ? booking.alternates : [];
  const phone =
    (booking.callee && booking.callee.phone) ||
    booking.phone ||
    booking.restaurant_phone ||
    "";
  return {
    kind: "phonezero-task",
    skill: "book-restaurant",
    spoken_name: booking.spoken_name,
    disclose_ai: booking.disclose_ai !== false,
    callee: { name: booking.restaurant, phone },
    callback: booking.callback,
    goal: "Book the table within the window.",
    opener: `I'd like to make a reservation for a party of ${party} on ${date} at ${preferred}. Do you have availability?`,
    constraints: [
      "Accept only the preferred time, ranked alternates, or a host offer inside the window.",
      "Never invent a time.",
    ],
    success: "Live host confirms read-back of party, date, agreed time, and booking name.",
    voicemail: `This is ${booking.spoken_name} calling for ${name} about a reservation for ${party} on ${date} at ${preferred}. Please call ${booking.callback}. Thank you.`,
    playbook:
      "Ask preferred first; then alternates in order; then in-window host offers. Mention special requests only after a time is under discussion.",
    facts: {
      party,
      date,
      preferred_time: preferred,
      window,
      alternates: alts,
      booking_name: name,
      special_requests: booking.special_requests || "none",
    },
  };
}

function validateTask(task) {
  if (!task || typeof task !== "object" || task.kind !== "phonezero-task") {
    throw new Error("task must be an object with kind phonezero-task");
  }
  const missing = TASK_ENVELOPE_KEYS.filter((k) => task[k] === undefined || task[k] === "");
  if (missing.length) throw new Error(`task missing: ${missing.join(", ")}`);
  if (!task.callee || typeof task.callee !== "object" || !task.callee.name) {
    throw new Error("task.callee must be an object with name");
  }
  if (!Array.isArray(task.constraints)) throw new Error("task.constraints must be an array");
  if (!task.facts || typeof task.facts !== "object") throw new Error("task.facts must be an object");
}

function normalizeTask(input) {
  if (!input || typeof input !== "object") throw new Error("task must be an object");
  const task = input.kind === "phonezero-booking" ? wrapBooking(input) : input;
  if (task.disclose_ai === undefined) task.disclose_ai = true;
  validateTask(task);
  return task;
}

function assertSlug(slug) {
  if (!slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
    throw new Error("slug must be lowercase letters, numbers, and hyphens");
  }
  return slug;
}

function templateFileName(slug) {
  return `${TEMPLATE_PREFIX}${assertSlug(slug)}.json`;
}

async function listCollectionDocs(collectionId) {
  const listed = await xaiJson(
    "GET",
    `${API}/collections/${encodeURIComponent(collectionId)}/documents`,
  );
  return listed.documents || listed.data || [];
}

async function listCollectionFileIds(collectionId, fileName) {
  const docs = await listCollectionDocs(collectionId);
  const ids = [];
  for (const doc of docs) {
    const name = documentNameOf(doc);
    const fid = documentFileIdOf(doc);
    if (name === fileName && fid) ids.push(fid);
  }
  return ids;
}

async function documentMeta(collectionId, fileId) {
  try {
    return await xaiJson(
      "GET",
      `${API}/collections/${encodeURIComponent(collectionId)}/documents/${encodeURIComponent(fileId)}`,
    );
  } catch {
    return null;
  }
}

async function deleteCollectionFile(collectionId, fileId) {
  try {
    await xaiJson(
      "DELETE",
      `${API}/collections/${encodeURIComponent(collectionId)}/documents/${encodeURIComponent(fileId)}`,
    );
  } catch {
    // already gone
  }
  try {
    await xaiJson("DELETE", `${API}/files/${encodeURIComponent(fileId)}`);
  } catch {
    // document delete can 404 the file
  }
  return { deleted: true, collection_id: collectionId, file_id: fileId };
}

async function deleteBooking(collectionId, fileId) {
  const doc = await documentMeta(collectionId, fileId);
  const name = documentNameOf(doc);
  if (name.startsWith(TEMPLATE_PREFIX)) {
    throw new Error("refusing to delete a template; use a template-specific delete if you add one");
  }
  if (name && name !== TASK_NAME && name !== LEGACY_BOOKING_NAME) {
    throw new Error(`refusing to delete ${name}; delete_booking is only for the live brief`);
  }
  return deleteCollectionFile(collectionId, fileId);
}

function isProcessed(status) {
  return (
    status === "DOCUMENT_STATUS_PROCESSED" ||
    status === "processed" ||
    status === "PROCESSED" ||
    status === 2 ||
    status === "2"
  );
}

function isFailed(status) {
  return (
    status === "DOCUMENT_STATUS_FAILED" ||
    status === "failed" ||
    status === "FAILED" ||
    status === 3 ||
    status === "3"
  );
}

async function waitProcessed(collectionId, fileId) {
  for (let i = 0; i < 40; i += 1) {
    const doc = await xaiJson(
      "GET",
      `${API}/collections/${encodeURIComponent(collectionId)}/documents/${encodeURIComponent(fileId)}`,
    );
    const status = doc.status;
    if (isProcessed(status)) {
      return { collection_id: collectionId, file_id: fileId, status: "processed" };
    }
    if (isFailed(status)) throw new Error("document processing failed");
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error("document not processed after 120s");
}

async function uploadCollectionJson(collectionId, fileName, payload, kind) {
  const bytes = Buffer.from(`${JSON.stringify(payload)}\n`, "utf8");
  const form = new FormData();
  form.append("expires_after", "3600");
  form.append("purpose", "assistants");
  form.append("file", new Blob([bytes], { type: "application/json" }), fileName);
  const uploaded = await xaiForm(`${API}/files`, form);
  const fileId = uploaded.id || "";
  if (!fileId) throw new Error("files upload missing id");
  await xaiJson("POST", `${API}/collections/${encodeURIComponent(collectionId)}/documents/${encodeURIComponent(fileId)}`, {
    body: {
      collection_id: collectionId,
      file_id: fileId,
      fields: { kind },
    },
  });
  return waitProcessed(collectionId, fileId);
}

async function putTask(input) {
  const task = normalizeTask(input);
  const { collection_id: collectionId } = await ensureCollection();
  for (const name of [TASK_NAME, LEGACY_BOOKING_NAME]) {
    for (const fid of await listCollectionFileIds(collectionId, name)) {
      await deleteCollectionFile(collectionId, fid);
    }
  }
  return uploadCollectionJson(collectionId, TASK_NAME, task, "phonezero-task");
}

function validateTemplate(slug, template) {
  assertSlug(slug);
  if (!template || typeof template !== "object") throw new Error("template must be an object");
  const body = {
    kind: "phonezero-template",
    slug,
    when_to_use: template.when_to_use || template.description || "",
    interview: Array.isArray(template.interview) ? template.interview : [],
    defaults: template.defaults && typeof template.defaults === "object" ? template.defaults : {},
  };
  if (template.freeze === true) body.freeze = true;
  return body;
}

async function putTemplate(slug, template) {
  const body = validateTemplate(slug, template);
  const fileName = templateFileName(slug);
  const { collection_id: collectionId } = await ensureCollection();
  for (const fid of await listCollectionFileIds(collectionId, fileName)) {
    await deleteCollectionFile(collectionId, fid);
  }
  const result = await uploadCollectionJson(collectionId, fileName, body, "phonezero-template");
  return { ...result, slug, file_name: fileName };
}

async function listTemplates() {
  const { collection_id: collectionId } = await ensureCollection();
  const docs = await listCollectionDocs(collectionId);
  const templates = [];
  for (const doc of docs) {
    const name = documentNameOf(doc);
    if (!name.startsWith(TEMPLATE_PREFIX) || !name.endsWith(".json")) continue;
    const slug = name.slice(TEMPLATE_PREFIX.length, -".json".length);
    templates.push({
      slug,
      file_name: name,
      file_id: documentFileIdOf(doc),
      collection_id: collectionId,
    });
  }
  return { collection_id: collectionId, templates };
}

async function getTemplate(slug) {
  const fileName = templateFileName(slug);
  const { collection_id: collectionId } = await ensureCollection();
  const docs = await listCollectionDocs(collectionId);
  const hit = docs.find((doc) => documentNameOf(doc) === fileName);
  if (!hit) throw new Error(`template not found: ${slug}`);
  const fileId = documentFileIdOf(hit);
  const file = await xaiJson("GET", `${API}/files/${encodeURIComponent(fileId)}/content`);
  return {
    collection_id: collectionId,
    file_id: fileId,
    slug,
    file_name: fileName,
    template: file,
  };
}

function parseSkillFrontmatter(text) {
  const match = text.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return { name: "", description: "" };
  const name = (match[1].match(/^name:\s*(.+)$/m) || [])[1] || "";
  const description = (match[1].match(/^description:\s*(.+)$/m) || [])[1] || "";
  return { name: name.trim(), description: description.trim() };
}

async function skillDirs() {
  const extra = envValue("PHONEZERO_SKILLS_DIR");
  return [
    BUNDLED_SKILLS_DIR,
    extra,
    join(homedir(), ".phonezero", "skills"),
    join(process.cwd(), ".phonezero", "skills"),
  ].filter(Boolean);
}

async function listPhoneSkills() {
  const seen = new Set();
  const skills = [];
  for (const root of await skillDirs()) {
    let entries = [];
    try {
      entries = await readdir(root, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const name = entry.name;
      if (name.startsWith("_") || name === "phonezero-runtime" || name === "phonezero") continue;
      if (seen.has(name)) continue;
      const skillMd = join(root, name, "SKILL.md");
      try {
        const st = await stat(skillMd);
        if (!st.isFile()) continue;
        const text = await readFile(skillMd, "utf8");
        const meta = parseSkillFrontmatter(text);
        seen.add(name);
        skills.push({
          name: meta.name || name,
          description: meta.description,
          source: join(root, name),
        });
      } catch {
        // skip
      }
    }
  }
  return { skills };
}

async function getPhoneSkill(name) {
  if (!name || name.startsWith("_") || name === "phonezero-runtime") {
    throw new Error("unknown skill");
  }
  for (const root of await skillDirs()) {
    const dir = join(root, name);
    const skillMd = join(dir, "SKILL.md");
    try {
      const text = await readFile(skillMd, "utf8");
      let schema = null;
      let playbook = "";
      try {
        schema = JSON.parse(await readFile(join(dir, "brief.schema.json"), "utf8"));
      } catch {
        schema = null;
      }
      try {
        playbook = await readFile(join(dir, "references", "voice-playbook.md"), "utf8");
      } catch {
        playbook = "";
      }
      return {
        name,
        source: dir,
        skill_md: text,
        brief_schema: schema,
        voice_playbook: playbook,
      };
    } catch {
      // try next root
    }
  }
  throw new Error(`skill not found: ${name}`);
}

async function transcribe(filePath, language) {
  const bytes = await readFile(filePath);
  const form = new FormData();
  form.append("multichannel", "true");
  form.append("format", "true");
  form.append("language", language || "en");
  form.append("file", new Blob([bytes]), basename(filePath));
  return xaiForm(`${API}/stt`, form);
}

function phoneItems(data) {
  return data.phoneNumbers || data.phone_numbers || data.data || [];
}

function summarizeNumber(item) {
  return {
    phone_number: item.phoneNumber || item.phone_number || "",
    phone_number_id: item.phoneNumberId || item.phone_number_id || "",
    origin: item.origin || "",
    agent_id: item.agentId || item.agent_id || "",
  };
}

async function listPhoneNumbers() {
  const data = await xaiJson("GET", `${PHONE_API}/phone-numbers`);
  return { numbers: phoneItems(data).filter((x) => x && typeof x === "object").map(summarizeNumber) };
}

async function registerByo(phoneNumber) {
  const listed = await listPhoneNumbers();
  const digits = phoneNumber.replace(/^\+/, "");
  const existing = listed.numbers.find(
    (n) => n.phone_number === phoneNumber || n.phone_number.replace(/^\+/, "") === digits,
  );
  if (existing) return { ...existing, created: false };
  const created = await xaiJson("POST", `${PHONE_API}/phone-numbers`, {
    body: { name: "PhoneZero", phoneNumber, origin: "byo_trunk" },
  });
  const item = created.phoneNumber && typeof created.phoneNumber === "object" ? created.phoneNumber : created;
  return { ...summarizeNumber(item), created: true };
}

async function attachAgent(phoneNumberId, agentId) {
  await xaiJson("PATCH", `${PHONE_API}/phone-numbers/${encodeURIComponent(phoneNumberId)}`, {
    body: {
      phoneNumber: { agentId },
      fieldMask: { paths: ["agent_id"] },
    },
  });
  return { attached: true, phone_number_id: phoneNumberId, agent_id: agentId };
}

async function callTool(name, args) {
  switch (name) {
    case "get_call_config":
      return getCallConfig();
    case "ensure_collection":
      return ensureCollection();
    case "put_task":
      return putTask(args.task);
    case "put_booking":
      return putTask(args.booking);
    case "delete_booking":
      return deleteBooking(args.collection_id, args.file_id);
    case "put_template":
      return putTemplate(args.slug, args.template);
    case "list_templates":
      return listTemplates();
    case "get_template":
      return getTemplate(args.slug);
    case "list_phone_skills":
      return listPhoneSkills();
    case "get_phone_skill":
      return getPhoneSkill(args.name);
    case "transcribe":
      return transcribe(args.file_path, args.language);
    case "list_phone_numbers":
      return listPhoneNumbers();
    case "register_byo_number":
      return registerByo(args.phone_number);
    case "attach_agent":
      return attachAgent(args.phone_number_id, args.agent_id);
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

function writeMessage(msg) {
  // Cursor's MCP client uses the official SDK: one JSON object per line, no
  // Content-Length headers. writeSync so unix-socket stdout cannot buffer the reply.
  writeSync(1, `${JSON.stringify(msg)}\n`);
}

function ok(id, result) {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function fail(id, code, message) {
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(msg) {
  if (!msg || typeof msg !== "object") return;
  const { id, method, params } = msg;
  if (method === "initialize") {
    ok(id, {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "phonezero-xai", version: "0.4.2" },
    });
    return;
  }
  if (method === "notifications/initialized" || method === "initialized") return;
  if (method === "tools/list") {
    ok(id, { tools: TOOLS });
    return;
  }
  if (method === "resources/list") {
    ok(id, { resources: [] });
    return;
  }
  if (method === "resources/templates/list") {
    ok(id, { resourceTemplates: [] });
    return;
  }
  if (method === "prompts/list") {
    ok(id, { prompts: [] });
    return;
  }
  if (method === "ping") {
    ok(id, {});
    return;
  }
  if (method === "tools/call") {
    try {
      const result = await callTool(params?.name, params?.arguments || {});
      ok(id, { content: [{ type: "text", text: JSON.stringify(result) }] });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      ok(id, { content: [{ type: "text", text: message }], isError: true });
    }
    return;
  }
  if (id !== undefined) fail(id, -32601, `Method not found: ${method}`);
}

function consumeBuffer(buf) {
  const messages = [];
  let rest = buf;
  while (rest.length) {
    const headerEnd = rest.indexOf("\r\n\r\n");
    const headerLooksLikeLength =
      headerEnd !== -1 && /^content-length:/i.test(rest.slice(0, headerEnd).toString("utf8"));
    if (headerLooksLikeLength) {
      const header = rest.slice(0, headerEnd).toString("utf8");
      const match = header.match(/content-length:\s*(\d+)/i);
      if (!match) {
        rest = rest.slice(headerEnd + 4);
        continue;
      }
      const len = Number(match[1]);
      const start = headerEnd + 4;
      if (rest.length < start + len) break;
      messages.push(JSON.parse(rest.slice(start, start + len).toString("utf8")));
      rest = rest.slice(start + len);
      continue;
    }
    const nl = rest.indexOf("\n");
    if (nl === -1) break;
    const line = rest.slice(0, nl).toString("utf8").replace(/\r$/, "").trim();
    rest = rest.slice(nl + 1);
    if (!line || /^content-length:/i.test(line)) continue;
    messages.push(JSON.parse(line));
  }
  return { messages, rest };
}

async function readLoop() {
  let buf = Buffer.alloc(0);
  let chain = Promise.resolve();
  process.stdin.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    let messages;
    try {
      const consumed = consumeBuffer(buf);
      messages = consumed.messages;
      buf = consumed.rest;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`phonezero-xai: parse error: ${message}\n`);
      return;
    }
    for (const msg of messages) {
      chain = chain.then(() => handle(msg)).catch((err) => {
        const message = err instanceof Error ? err.message : String(err);
        process.stderr.write(`phonezero-xai: handle error: ${message}\n`);
      });
    }
  });
  process.stdin.on("error", (err) => {
    process.stderr.write(`phonezero-xai: stdin error: ${err.message}\n`);
  });
  process.stdin.resume();
}

async function selfTest() {
  const child = spawn(process.execPath, [fileURLToPath(import.meta.url)], {
    stdio: ["pipe", "pipe", "inherit"],
    env: { ...process.env, XAI_API_KEY: "" },
  });
  const send = (msg) => {
    child.stdin.write(`${JSON.stringify(msg)}\n`);
  };
  let out = Buffer.alloc(0);
  const readOne = () =>
    new Promise((resolve, reject) => {
      const onData = (chunk) => {
        out = Buffer.concat([out, chunk]);
        const nl = out.indexOf("\n");
        if (nl === -1) return;
        const raw = out.slice(0, nl).toString("utf8").replace(/\r$/, "");
        out = out.slice(nl + 1);
        child.stdout.off("data", onData);
        resolve(JSON.parse(raw));
      };
      child.stdout.on("data", onData);
      setTimeout(() => reject(new Error("self-test timeout")), 5000);
    });
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "self-test", version: "0" } } });
  const init = await readOne();
  if (init.result?.serverInfo?.name !== "phonezero-xai") throw new Error("bad initialize");
  send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  const listed = await readOne();
  const names = (listed.result?.tools || []).map((t) => t.name);
  for (const need of [
    "get_call_config",
    "put_booking",
    "put_task",
    "put_template",
    "list_templates",
    "get_template",
    "list_phone_skills",
    "get_phone_skill",
    "transcribe",
  ]) {
    if (!names.includes(need)) throw new Error(`missing tool ${need}`);
  }
  child.kill();

  const sampleBooking = {
    kind: "phonezero-booking",
    spoken_name: "PhoneZero",
    restaurant: "Joe's Pizza",
    party: 2,
    date: "Friday, August 28",
    preferred_time: "7:00 PM",
    window: "6:30 PM to 8:00 PM",
    alternates: ["6:45 PM", "7:15 PM"],
    booking_name: "Alex Example",
    callback: "+15555550199",
    special_requests: "none",
  };
  const wrapped = wrapBooking(sampleBooking);
  if (wrapped.kind !== "phonezero-task" || wrapped.skill !== "book-restaurant") {
    throw new Error("wrapBooking kind/skill");
  }
  if (!wrapped.opener.includes("reservation") || wrapped.callee.name !== "Joe's Pizza") {
    throw new Error("wrapBooking opener/callee");
  }
  validateTask(wrapped);
  validateTemplate("confirm-hours", {
    when_to_use: "Confirm opening hours",
    interview: ["business name", "phone"],
    defaults: { goal: "Confirm today's hours." },
  });
  try {
    validateTemplate("Bad Slug", {});
    throw new Error("slug should reject");
  } catch (err) {
    if (!(err instanceof Error) || !err.message.includes("slug")) throw err;
  }

  const listedSkills = await listPhoneSkills();
  const skillNames = listedSkills.skills.map((s) => s.name);
  for (const need of ["book-restaurant", "confirm-business-hours"]) {
    if (!skillNames.includes(need)) throw new Error(`missing bundled skill ${need}`);
  }
  if (skillNames.includes("phonezero-runtime") || skillNames.includes("phonezero")) {
    throw new Error("list_phone_skills must skip runtime and deprecated stub");
  }
  const restaurant = await getPhoneSkill("book-restaurant");
  if (!restaurant.brief_schema || restaurant.brief_schema.properties?.skill?.const !== "book-restaurant") {
    throw new Error("get_phone_skill book-restaurant schema");
  }

  process.stdout.write("xai-mcp self-test ok\n");
}

if (process.argv.includes("--self-test")) {
  await selfTest();
} else {
  await readLoop();
}
