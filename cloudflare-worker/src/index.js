/**
 * DocumentBrain API Proxy — Cloudflare Worker
 *
 * Proxies requests to Gemini (key injected server-side) and gates access with:
 *   - x-app-secret           shared app secret (cheap first gate, every route)
 *   - Apple App Attest        per-device identity → short-lived HMAC session token
 *   - per-device daily quota  + global daily cap (anti-flood / cost ceiling)
 *
 * Routes (all POST):
 *   /attest/challenge → issue a per-device nonce
 *   /attest/verify    → verify attestation, return session token
 *   /attest/refresh   → verify assertion, return a fresh session token
 *   /chat             → gemini:generateContent        (token required when REQUIRE_ATTESTATION="true")
 *   /chat/stream      → gemini:streamGenerateContent  (SSE)
 */

import { verifyToken } from "./attest.js";

// Durable Object classes must be exported from the Worker entry module.
export { DeviceAttestation, GlobalLimiter } from "./device.js";

const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const GEMINI_MODEL = "gemini-2.5-flash";

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return corsResponse(new Response(null, { status: 204 }));
    if (request.method !== "POST") return corsResponse(new Response("Method not allowed", { status: 405 }));

    const url = new URL(request.url);

    // Shared app secret — first cheap gate for every route
    if (request.headers.get("x-app-secret") !== env.APP_SECRET) {
      return corsResponse(new Response("Unauthorized", { status: 401 }));
    }

    try {
      switch (url.pathname) {
        case "/attest/challenge": return await handleChallenge(request, env);
        case "/attest/verify":    return await handleAttestVerify(request, env);
        case "/attest/refresh":   return await handleAttestRefresh(request, env);
        case "/chat":             return await handleGatedChat(request, env, false);
        case "/chat/stream":      return await handleGatedChat(request, env, true);
        default:                  return corsResponse(new Response("Not Found", { status: 404 }));
      }
    } catch (err) {
      return corsResponse(Response.json({ error: err.message }, { status: 500 }));
    }
  },
};

// ---------------------------------------------------------------------------
// Attestation endpoints
// ---------------------------------------------------------------------------

async function handleChallenge(request, env) {
  const { keyId } = await request.json();
  if (!keyId) return corsResponse(new Response("Missing keyId", { status: 400 }));
  const result = await env.DEVICE_DO.getByName(keyId).issueChallenge();
  return corsResponse(Response.json(result));
}

async function handleAttestVerify(request, env) {
  const { keyId, attestation } = await request.json();
  if (!keyId || !attestation) return corsResponse(new Response("Missing keyId/attestation", { status: 400 }));
  const result = await env.DEVICE_DO.getByName(keyId).verify({ attestationB64: attestation, keyIdB64: keyId });
  return corsResponse(Response.json(result, { status: result.ok ? 200 : 401 }));
}

async function handleAttestRefresh(request, env) {
  const { keyId, assertion, clientData } = await request.json();
  if (!keyId || !assertion || !clientData) return corsResponse(new Response("Missing fields", { status: 400 }));
  const result = await env.DEVICE_DO.getByName(keyId).refresh({
    assertionB64: assertion,
    clientDataB64: clientData,
    keyIdB64: keyId,
  });
  return corsResponse(Response.json(result, { status: result.ok ? 200 : 401 }));
}

// ---------------------------------------------------------------------------
// Gated chat
// ---------------------------------------------------------------------------

async function handleGatedChat(request, env, stream) {
  const requireAttest = env.REQUIRE_ATTESTATION === "true";

  // Identify the device via the session token
  let keyId = null;
  const auth = request.headers.get("Authorization") || "";
  if (auth.startsWith("Bearer ")) {
    const v = await verifyToken(auth.slice(7), env.TOKEN_SECRET || env.APP_SECRET);
    if (v.ok) keyId = v.keyId;
  }
  if (requireAttest && !keyId) {
    return corsResponse(new Response("Attestation required", { status: 401 }));
  }

  // Per-IP daily limit — works WITHOUT App Attest, so it protects from day one
  // (a single IP can't drain the whole global cap on its own).
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const perIp = parseInt(env.PER_IP_DAILY || "100");
  const ipResult = await env.GLOBAL_DO.getByName(`ip:${ip}`).consume(perIp);
  if (!ipResult.allowed) return corsResponse(new Response("Daily IP limit reached", { status: 429 }));

  // Per-device daily quota (only when we have an attested identity)
  if (keyId) {
    const limit = parseInt(env.PER_DEVICE_DAILY || "50");
    const q = await env.DEVICE_DO.getByName(keyId).consumeQuota(limit);
    if (!q.allowed) return corsResponse(new Response("Daily device limit reached", { status: 429 }));
  }

  // Global daily cap (always) — bounds worst-case cost regardless of identity
  const globalLimit = parseInt(env.GLOBAL_DAILY || "5000");
  const g = await env.GLOBAL_DO.getByName("global").consume(globalLimit);
  if (!g.allowed) return corsResponse(new Response("Service temporarily unavailable", { status: 429 }));

  return forwardToGemini(request, env, stream);
}

async function forwardToGemini(request, env, stream) {
  const body = await request.json();
  const geminiPath = stream
    ? `${GEMINI_BASE}/${GEMINI_MODEL}:streamGenerateContent?alt=sse`
    : `${GEMINI_BASE}/${GEMINI_MODEL}:generateContent`;

  const geminiResponse = await fetch(geminiPath, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
    body: JSON.stringify(body),
  });

  if (!geminiResponse.ok) {
    const errorText = await geminiResponse.text();
    return corsResponse(new Response(errorText, { status: geminiResponse.status }));
  }

  if (stream) {
    const headers = new Headers(geminiResponse.headers);
    headers.set("Access-Control-Allow-Origin", "*");
    return new Response(geminiResponse.body, { status: geminiResponse.status, headers });
  }

  return corsResponse(Response.json(await geminiResponse.json()));
}

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

function corsResponse(response) {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Allow-Headers", "Content-Type, x-app-secret, Authorization");
  headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return new Response(response.body, { status: response.status, headers });
}
