# App Attest — setup & rollout

This proxy gates `/chat` with Apple App Attest so only genuine instances of the
DocumentBrain app can use it, plus per-device and global rate limits to bound
abuse and cost.

> ⚠️ **Cannot be tested in the Simulator.** `DCAppAttestService.isSupported` is
> `false` there. Everything below must be validated on a **physical device**.

## Architecture

```
1. ATTESTATION (once per install)
   App: generateKey() → keyId (Secure Enclave)
   App → POST /attest/challenge {keyId}        → nonce
   App: attestKey(keyId, SHA256(nonce))         → attestation
   App → POST /attest/verify {keyId, attestation}
   Worker: verify attestation vs Apple root CA, store key, issue HMAC token

2. REQUESTS (hot path)
   App → POST /chat  Authorization: Bearer <token>
   Worker: verify token → per-device quota → global cap → proxy to Gemini
   Token expired → App refreshes with an assertion (/attest/refresh)
```

State lives in two Durable Objects (`DeviceAttestation` per device, `GlobalLimiter`
singleton), created automatically by the `v1` migration on first deploy.

## One-time setup

### 1. Apple Developer

- Enable the **App Attest** capability for the App ID (developer.apple.com → Identifiers).
- In Xcode → target → **Signing & Capabilities → + Capability → App Attest**.
  This adds `com.apple.developer.devicecheck.appattest-environment` to the
  entitlements (`development` for testing, `production` for the App Store).

### 2. The real Apple Root CA  ⚠️ REQUIRED

`src/attest.js` ships with an **empty** `APPLE_APP_ATTEST_ROOT_CA_PEM` and
**fails closed** until you paste the genuine certificate. Download
"Apple App Attestation Root CA" from <https://www.apple.com/certificateauthority/>
and paste the PEM into that constant.

### 3. Worker config & secrets

```bash
cd cloudflare-worker

# Secrets (never committed)
wrangler secret put GEMINI_API_KEY
wrangler secret put APP_SECRET
wrangler secret put TOKEN_SECRET     # HMAC key for session tokens

# Verify these in wrangler.toml match your signing:
#   APPLE_TEAM_ID    = "72929TBAA4"
#   APPLE_BUNDLE_ID  = "Jorge-Perez-Campos.DocumentBrain"

wrangler deploy   # creates the Durable Objects via the v1 migration
```

## Staged rollout (avoid locking out the live app)

1. **Deploy the Worker with `REQUIRE_ATTESTATION = "false"`** (current default).
   The existing app keeps working; the global cap is already enforced.
2. **Ship the App-Attest-enabled app build.** It starts sending tokens, but they
   aren't required yet.
3. **Validate on a real device:** trigger a chat, confirm `/attest/verify` returns
   `{ ok: true, token }` and `/chat` succeeds with the bearer token. Watch
   `wrangler tail` for `verifyAttestation` rejections (`reason` field).
4. **Only once attestation verifies reliably**, set `REQUIRE_ATTESTATION = "true"`
   and redeploy. Now untokened requests get `401`.

## ⚠️ Verify before trusting

The attestation/assertion verification in `src/attest.js` (CBOR + DER/ASN.1 +
certificate-chain validation) follows Apple's documented algorithm but has **not
been tested against real attestations**. Before flipping `REQUIRE_ATTESTATION`
on, confirm with real device attestations that:

- genuine attestations are **accepted**, and
- tampered/foreign ones are **rejected** (check the `reason` codes).

Consider cross-checking the first real attestation against a maintained
App Attest verification library.

## Tunables (`wrangler.toml [vars]`)

| Var | Default | Meaning |
|---|---|---|
| `REQUIRE_ATTESTATION` | `false` | When `true`, `/chat` requires a valid token |
| `PER_DEVICE_DAILY` | `50` | Max `/chat` requests per device per day |
| `GLOBAL_DAILY` | `5000` | Max `/chat` requests across all devices per day |
| `TOKEN_TTL_SECONDS` | `86400` | Session-token lifetime |

## Defense in depth (still recommended)

App Attest + rate limits raise the bar a lot, but also set a hard ceiling at the
source: in Google AI Studio / Cloud Console, cap the **Gemini API quota** and add
a **billing budget alert**. And enable Cloudflare **Bot Fight Mode** + a
**rate-limiting rule** at the edge.
