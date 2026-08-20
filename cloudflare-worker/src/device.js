/**
 * Durable Objects for App Attest device state + rate limiting.
 *
 * DeviceAttestation — one instance per device (keyed by the App Attest keyId).
 *   Stores the attested public key + signature counter (anti-replay) and a
 *   per-device daily request counter. Strongly consistent, so counters can't
 *   be raced.
 *
 * GlobalLimiter — a single instance ("global") holding a daily request ceiling
 *   across all devices, bounding worst-case cost regardless of identity.
 */

import { DurableObject } from "cloudflare:workers";
import {
  randomChallengeB64,
  verifyAttestation,
  verifyAssertion,
  issueToken,
  b64ToBytes,
  bytesToB64,
  bytesEqual,
} from "./attest.js";

const CHALLENGE_TTL_MS = 5 * 60 * 1000; // nonce valid for 5 minutes

function todayUTC() {
  return new Date().toISOString().slice(0, 10); // "2026-06-10"
}

export class DeviceAttestation extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS device (
          id            INTEGER PRIMARY KEY CHECK (id = 0),
          public_key    TEXT,
          sign_count    INTEGER NOT NULL DEFAULT 0,
          challenge     TEXT,
          challenge_exp INTEGER,
          attested      INTEGER NOT NULL DEFAULT 0,
          day           TEXT,
          day_count     INTEGER NOT NULL DEFAULT 0
        );
      `);
      this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO device (id) VALUES (0);`);
    });
  }

  _row() {
    return this.ctx.storage.sql.exec("SELECT * FROM device WHERE id = 0").one();
  }

  /** Phase 1a: issue a fresh nonce for the device to attest against. */
  async issueChallenge() {
    const challenge = randomChallengeB64();
    this.ctx.storage.sql.exec(
      "UPDATE device SET challenge = ?, challenge_exp = ? WHERE id = 0",
      challenge,
      Date.now() + CHALLENGE_TTL_MS
    );
    return { challenge };
  }

  /** Phase 1b: verify the one-time attestation, persist the key, issue a token. */
  async verify({ attestationB64, keyIdB64 }) {
    const row = this._row();
    if (!row.challenge || !row.challenge_exp || row.challenge_exp < Date.now()) {
      return { ok: false, reason: "no-challenge" };
    }

    const res = await verifyAttestation({
      attestation: b64ToBytes(attestationB64),
      keyId: b64ToBytes(keyIdB64),
      challenge: row.challenge,
      teamId: this.env.APPLE_TEAM_ID,
      bundleId: this.env.APPLE_BUNDLE_ID,
    });
    if (!res.ok) return res;

    // Persist first, then nothing else depends on in-memory state.
    this.ctx.storage.sql.exec(
      "UPDATE device SET public_key = ?, sign_count = ?, attested = 1, challenge = NULL, challenge_exp = NULL WHERE id = 0",
      bytesToB64(res.publicKeyDer),
      res.signCount
    );

    const token = await issueToken(keyIdB64, this._tokenSecret(), this._tokenTtl());
    return { ok: true, token };
  }

  /** Phase 2: verify an assertion (proves key possession) and mint a fresh token. */
  async refresh({ assertionB64, clientDataB64, keyIdB64 }) {
    const row = this._row();
    if (!row.attested || !row.public_key) return { ok: false, reason: "not-attested" };
    if (!row.challenge || !row.challenge_exp || row.challenge_exp < Date.now()) {
      return { ok: false, reason: "no-challenge" };
    }
    // clientData must be the exact challenge we issued — otherwise the /attest/challenge
    // round trip binds nothing and a stale/foreign assertion could be replayed.
    if (!bytesEqual(b64ToBytes(clientDataB64), b64ToBytes(row.challenge))) {
      return { ok: false, reason: "challenge-mismatch" };
    }

    const res = await verifyAssertion({
      assertion: b64ToBytes(assertionB64),
      clientData: b64ToBytes(clientDataB64),
      publicKeyDer: b64ToBytes(row.public_key),
      prevCount: row.sign_count,
      teamId: this.env.APPLE_TEAM_ID,
      bundleId: this.env.APPLE_BUNDLE_ID,
    });
    if (!res.ok) return res;

    this.ctx.storage.sql.exec(
      "UPDATE device SET sign_count = ?, challenge = NULL, challenge_exp = NULL WHERE id = 0",
      res.newCount
    );
    const token = await issueToken(keyIdB64, this._tokenSecret(), this._tokenTtl());
    return { ok: true, token };
  }

  /** Per-device daily quota. Returns {allowed, remaining}. */
  async consumeQuota(limit) {
    const row = this._row();
    const today = todayUTC();
    let count = row.day === today ? row.day_count : 0;
    if (count >= limit) return { allowed: false, remaining: 0 };
    count += 1;
    this.ctx.storage.sql.exec("UPDATE device SET day = ?, day_count = ? WHERE id = 0", today, count);
    return { allowed: true, remaining: limit - count };
  }

  _tokenSecret() {
    // No fallback to APP_SECRET: that value is embedded in the client app bundle
    // and extractable by reverse engineering, so using it to sign session tokens
    // would let anyone forge a token without ever attesting.
    if (!this.env.TOKEN_SECRET) throw new Error("TOKEN_SECRET is not configured");
    return this.env.TOKEN_SECRET;
  }

  _tokenTtl() {
    return parseInt(this.env.TOKEN_TTL_SECONDS || "86400");
  }
}

export class GlobalLimiter extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS counter (
          id    INTEGER PRIMARY KEY CHECK (id = 0),
          day   TEXT,
          count INTEGER NOT NULL DEFAULT 0
        );
      `);
      this.ctx.storage.sql.exec(`INSERT OR IGNORE INTO counter (id) VALUES (0);`);
    });
  }

  /** Global daily ceiling across all devices. Returns {allowed}. */
  async consume(limit) {
    const row = this.ctx.storage.sql.exec("SELECT * FROM counter WHERE id = 0").one();
    const today = todayUTC();
    let count = row.day === today ? row.count : 0;
    if (count >= limit) return { allowed: false };
    count += 1;
    this.ctx.storage.sql.exec("UPDATE counter SET day = ?, count = ? WHERE id = 0", today, count);
    return { allowed: true };
  }
}
