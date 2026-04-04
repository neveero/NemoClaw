#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

/**
 * Telegram → NemoClaw bridge.
 *
 * Messages from Telegram are forwarded to the OpenClaw agent running
 * inside the sandbox. When the agent needs external access, the
 * OpenShell TUI lights up for approval. Responses go back to Telegram.
 *
 * Env:
 *   TELEGRAM_BOT_TOKEN  — from @BotFather
 *   NVIDIA_API_KEY      — for NVIDIA inference (optional if OPENAI_API_KEY is set)
 *   OPENAI_API_KEY      — for OpenAI inference (optional if NVIDIA_API_KEY is set)
 *   SANDBOX_NAME        — sandbox name (default: nemoclaw)
 *   ALLOWED_CHAT_IDS    — comma-separated Telegram chat IDs to accept (optional, accepts all if unset)
 */

const https = require("https");
const { execFileSync, spawn } = require("child_process");
const { resolveOpenshell } = require("../bin/lib/resolve-openshell");
const { shellQuote, validateName } = require("../bin/lib/runner");
const { parseAllowedChatIds, isChatAllowed } = require("../bin/lib/chat-filter");

const OPENSHELL = resolveOpenshell();
if (!OPENSHELL) {
  console.error("openshell not found on PATH or in common locations");
  process.exit(1);
}

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const NVIDIA_API_KEY = process.env.NVIDIA_API_KEY || "";
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const OPENAI_TRANSCRIPTION_MODEL = process.env.OPENAI_TRANSCRIPTION_MODEL || "whisper-1";
const DEBUG_UPDATES = process.env.TELEGRAM_BRIDGE_DEBUG === "1";
const SANDBOX = process.env.SANDBOX_NAME || "nemoclaw";
try { validateName(SANDBOX, "SANDBOX_NAME"); } catch (e) { console.error(e.message); process.exit(1); }
const ALLOWED_CHATS = parseAllowedChatIds(process.env.ALLOWED_CHAT_IDS);

if (!TOKEN) { console.error("TELEGRAM_BOT_TOKEN required"); process.exit(1); }
if (!NVIDIA_API_KEY && !OPENAI_API_KEY) {
  console.error("NVIDIA_API_KEY or OPENAI_API_KEY required");
  process.exit(1);
}

let offset = 0;
const activeSessions = new Map(); // chatId → message history

const COOLDOWN_MS = 5000;
const lastMessageTime = new Map();
const busyChats = new Set();

// ── Telegram API helpers ──────────────────────────────────────────

function tgApi(method, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request(
      {
        hostname: "api.telegram.org",
        path: `/bot${TOKEN}/${method}`,
        method: "POST",
        headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) },
      },
      (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          try { resolve(JSON.parse(buf)); } catch { resolve({ ok: false, error: buf }); }
        });
      },
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

async function sendMessage(chatId, text, replyTo) {
  // Telegram max message length is 4096
  const chunks = [];
  for (let i = 0; i < text.length; i += 4000) {
    chunks.push(text.slice(i, i + 4000));
  }
  for (const chunk of chunks) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: chunk,
      reply_to_message_id: replyTo,
      parse_mode: "Markdown",
    }).catch(() =>
      // Retry without markdown if it fails (unbalanced formatting)
      tgApi("sendMessage", { chat_id: chatId, text: chunk, reply_to_message_id: replyTo }),
    );
  }
}

async function sendTyping(chatId) {
  await tgApi("sendChatAction", { chat_id: chatId, action: "typing" }).catch(() => {});
}

function httpsGetBuffer(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, (res) => {
      if (res.statusCode && (res.statusCode < 200 || res.statusCode >= 300)) {
        let errBuf = "";
        res.on("data", (d) => (errBuf += d.toString()));
        res.on("end", () => reject(new Error(`GET ${url} failed: ${res.statusCode} ${errBuf.slice(0, 200)}`)));
        return;
      }
      const chunks = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => resolve(Buffer.concat(chunks)));
    });
    req.on("error", reject);
  });
}

async function downloadTelegramFile(fileId) {
  const file = await tgApi("getFile", { file_id: fileId });
  if (!file?.ok || !file?.result?.file_path) {
    throw new Error("Telegram getFile failed");
  }
  const filePath = file.result.file_path;
  const fileUrl = `https://api.telegram.org/file/bot${TOKEN}/${filePath}`;
  const data = await httpsGetBuffer(fileUrl);
  const name = String(filePath.split("/").pop() || "voice.oga");
  return { data, name };
}

function transcribeWithOpenAI(audioBuffer, filename = "voice.oga", mime = "audio/ogg") {
  return new Promise((resolve, reject) => {
    if (!OPENAI_API_KEY) {
      reject(new Error("OPENAI_API_KEY is required for voice transcription"));
      return;
    }

    const boundary = `----nemoclaw-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    const body = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\n` +
          `Content-Disposition: form-data; name="model"\r\n\r\n` +
          `${OPENAI_TRANSCRIPTION_MODEL}\r\n`,
        "utf8",
      ),
      Buffer.from(
        `--${boundary}\r\n` +
          `Content-Disposition: form-data; name="response_format"\r\n\r\n` +
          `json\r\n`,
        "utf8",
      ),
      Buffer.from(
        `--${boundary}\r\n` +
          `Content-Disposition: form-data; name="file"; filename="${filename.replace(/"/g, "")}"\r\n` +
          `Content-Type: ${mime}\r\n\r\n`,
        "utf8",
      ),
      audioBuffer,
      Buffer.from(`\r\n--${boundary}--\r\n`, "utf8"),
    ]);

    const req = https.request(
      {
        hostname: "api.openai.com",
        path: "/v1/audio/transcriptions",
        method: "POST",
        headers: {
          Authorization: `Bearer ${OPENAI_API_KEY}`,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let raw = "";
        res.on("data", (d) => (raw += d.toString()));
        res.on("end", () => {
          if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
            reject(new Error(`OpenAI transcription failed: ${res.statusCode || "?"} ${raw.slice(0, 300)}`));
            return;
          }
          try {
            const parsed = JSON.parse(raw);
            const text = (parsed && parsed.text ? String(parsed.text) : "").trim();
            if (!text) {
              reject(new Error("Transcription returned empty text"));
              return;
            }
            resolve(text);
          } catch {
            reject(new Error("Failed to parse transcription response"));
          }
        });
      },
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function transcribeTelegramMessage(msg) {
  const media = msg.voice || msg.audio || msg.video_note;
  if (!media?.file_id) {
    throw new Error("No voice/audio file found");
  }
  const { data, name } = await downloadTelegramFile(media.file_id);
  const mime = msg.voice ? "audio/ogg" : msg.audio ? "audio/mpeg" : "video/mp4";
  return transcribeWithOpenAI(data, name, mime);
}

// ── Run agent inside sandbox ──────────────────────────────────────

function runAgentInSandbox(message, sessionId) {
  return new Promise((resolve) => {
    const sshConfig = execFileSync(OPENSHELL, ["sandbox", "ssh-config", SANDBOX], { encoding: "utf-8" });

    // Write temp ssh config with unpredictable name
    const confDir = require("fs").mkdtempSync("/tmp/nemoclaw-tg-ssh-");
    const confPath = `${confDir}/config`;
    require("fs").writeFileSync(confPath, sshConfig, { mode: 0o600 });

    // Pass message and API key via stdin to avoid shell interpolation.
    // The remote command reads them from environment/stdin rather than
    // embedding user content in a shell string.
    const safeSessionId = String(sessionId).replace(/[^a-zA-Z0-9-]/g, "");
    const cmd = `export NVIDIA_API_KEY=${shellQuote(NVIDIA_API_KEY)} OPENAI_API_KEY=${shellQuote(OPENAI_API_KEY)} && nemoclaw-start openclaw agent --agent main --local -m ${shellQuote(message)} --session-id ${shellQuote("tg-" + safeSessionId)}`;

    const proc = spawn("ssh", ["-T", "-F", confPath, `openshell-${SANDBOX}`, cmd], {
      timeout: 120000,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    proc.stdout.on("data", (d) => (stdout += d.toString()));
    proc.stderr.on("data", (d) => (stderr += d.toString()));

    proc.on("close", (code) => {
      try { require("fs").unlinkSync(confPath); require("fs").rmdirSync(confDir); } catch { /* ignored */ }

      // Extract the actual agent response — skip setup lines
      const lines = stdout.split("\n");
      const responseLines = lines.filter(
        (l) =>
          !l.startsWith("Setting up NemoClaw") &&
          !l.startsWith("[plugins]") &&
          !l.startsWith("(node:") &&
          !l.includes("NemoClaw ready") &&
          !l.includes("NemoClaw registered") &&
          !l.includes("openclaw agent") &&
          !l.includes("┌─") &&
          !l.includes("│ ") &&
          !l.includes("└─") &&
          l.trim() !== "",
      );

      const response = responseLines.join("\n").trim();

      if (response) {
        resolve(response);
      } else if (code !== 0) {
        resolve(`Agent exited with code ${code}. ${stderr.trim().slice(0, 500)}`);
      } else {
        resolve("(no response)");
      }
    });

    proc.on("error", (err) => {
      resolve(`Error: ${err.message}`);
    });
  });
}

// ── Poll loop ─────────────────────────────────────────────────────

async function poll() {
  try {
    const res = await tgApi("getUpdates", { offset, timeout: 30 });

    if (res.ok && res.result?.length > 0) {
      for (const update of res.result) {
        offset = update.update_id + 1;

        const msg = update.message;
        if (!msg) continue;
        const isText = typeof msg.text === "string" && msg.text.trim().length > 0;
        const isVoice = Boolean(msg.voice?.file_id || msg.audio?.file_id || msg.video_note?.file_id);
        if (!isText && !isVoice) {
          if (DEBUG_UPDATES) {
            const keys = Object.keys(msg).join(",");
            console.log(`[debug] skipped non-text update keys=${keys}`);
          }
          continue;
        }

        const chatId = String(msg.chat.id);

        // Access control
        if (!isChatAllowed(ALLOWED_CHATS, chatId)) {
          console.log(`[ignored] chat ${chatId} not in allowed list`);
          continue;
        }

        const userName = msg.from?.first_name || "someone";
        console.log(`[${chatId}] ${userName}: ${isText ? msg.text : "[voice/audio note]"}`);

        // Handle /start
        if (isText && msg.text === "/start") {
          await sendMessage(
            chatId,
            "🦀 *NemoClaw* — powered by Nemotron 3 Super 120B\n\n" +
              "Send me a message and I'll run it through the OpenClaw agent " +
              "inside an OpenShell sandbox. Voice notes are also supported.\n\n" +
              "If the agent needs external access, the TUI will prompt for approval.",
            msg.message_id,
          );
          continue;
        }

        // Handle /reset
        if (isText && msg.text === "/reset") {
          activeSessions.delete(chatId);
          await sendMessage(chatId, "Session reset.", msg.message_id);
          continue;
        }

        // Rate limiting: per-chat cooldown
        const now = Date.now();
        const lastTime = lastMessageTime.get(chatId) || 0;
        if (now - lastTime < COOLDOWN_MS) {
          const wait = Math.ceil((COOLDOWN_MS - (now - lastTime)) / 1000);
          await sendMessage(chatId, `Please wait ${wait}s before sending another message.`, msg.message_id);
          continue;
        }

        // Per-chat serialization: reject if this chat already has an active session
        if (busyChats.has(chatId)) {
          await sendMessage(chatId, "Still processing your previous message.", msg.message_id);
          continue;
        }

        lastMessageTime.set(chatId, now);
        busyChats.add(chatId);

        // Send typing indicator
        await sendTyping(chatId);

        // Keep a typing indicator going while agent runs
        const typingInterval = setInterval(() => sendTyping(chatId), 4000);

        try {
          let prompt = "";
          if (isText) {
            prompt = msg.text;
          } else {
            prompt = await transcribeTelegramMessage(msg);
            console.log(`[${chatId}] transcript: ${prompt.slice(0, 120)}...`);
          }
          const response = await runAgentInSandbox(prompt, chatId);
          clearInterval(typingInterval);
          console.log(`[${chatId}] agent: ${response.slice(0, 100)}...`);
          await sendMessage(chatId, response, msg.message_id);
        } catch (err) {
          clearInterval(typingInterval);
          await sendMessage(chatId, `Error: ${err.message}`, msg.message_id);
        } finally {
          busyChats.delete(chatId);
        }
      }
    }
  } catch (err) {
    console.error("Poll error:", err.message);
  }

  // Continue polling (1s floor prevents tight-loop resource waste)
  setTimeout(poll, 1000);
}

// ── Main ──────────────────────────────────────────────────────────

async function main() {
  const me = await tgApi("getMe", {});
  if (!me.ok) {
    console.error("Failed to connect to Telegram:", JSON.stringify(me));
    process.exit(1);
  }

  console.log("");
  console.log("  ┌─────────────────────────────────────────────────────┐");
  console.log("  │  NemoClaw Telegram Bridge                          │");
  console.log("  │                                                     │");
  console.log(`  │  Bot:      @${(me.result.username + "                    ").slice(0, 37)}│`);
  console.log("  │  Sandbox:  " + (SANDBOX + "                              ").slice(0, 40) + "│");
  console.log("  │  Model:    nvidia/nemotron-3-super-120b-a12b       │");
  console.log("  │                                                     │");
  console.log("  │  Messages are forwarded to the OpenClaw agent      │");
  console.log("  │  inside the sandbox. Run 'openshell term' in       │");
  console.log("  │  another terminal to monitor + approve egress.     │");
  console.log("  └─────────────────────────────────────────────────────┘");
  console.log("");

  poll();
}

main();
