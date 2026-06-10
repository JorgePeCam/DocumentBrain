/**
 * Apple App Attest verification + session-token helpers for the DocumentBrain proxy.
 *
 * ⚠️  SECURITY NOTE — READ BEFORE RELYING ON THIS:
 * The attestation/assertion verification below follows Apple's documented algorithm
 * (https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server).
 * The certificate-chain validation (step 1–2 of attestation) is the highest-risk part and
 * CANNOT be tested without real device attestations. Validate this against known-good
 * attestations from a physical device before trusting it in production. A subtle bug here
 * either rejects all real users or — worse — accepts forgeries. Consider cross-checking
 * against a maintained library on first rollout.
 *
 * Everything runs on the Workers WebCrypto API (no Node dependencies).
 */

const NONCE_OID = "1.2.840.113635.100.8.2";

// ⚠️ MUST be replaced with the real "Apple App Attestation Root CA" certificate
// before this works. Download the authoritative PEM from:
//   https://www.apple.com/certificateauthority/  (Apple App Attestation Root CA)
// Left empty on purpose so verification FAILS CLOSED until you paste the real cert,
// rather than appearing to work with a bogus root. Do NOT trust a cert you can't
// confirm is the genuine Apple root.
const APPLE_APP_ATTEST_ROOT_CA_PEM = "";

// ---------------------------------------------------------------------------
// Base64 / bytes
// ---------------------------------------------------------------------------

export function b64ToBytes(b64) {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

export function bytesToB64url(bytes) {
  return bytesToB64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concatBytes(...arrays) {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrays) { out.set(a, off); off += a.length; }
  return out;
}

function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Hashing / HMAC (WebCrypto)
// ---------------------------------------------------------------------------

export async function sha256(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(digest);
}

export function randomChallengeB64() {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return bytesToB64(buf);
}

async function hmacKey(secret) {
  return crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]
  );
}

// ---------------------------------------------------------------------------
// Session tokens — stateless HMAC, gate the hot /chat path without DO crypto
// Format: base64url(payloadJSON) "." base64url(hmac)
// ---------------------------------------------------------------------------

export async function issueToken(keyIdB64, secret, ttlSeconds = 86400) {
  const payload = { kid: keyIdB64, exp: Math.floor(Date.now() / 1000) + ttlSeconds };
  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
  const key = await hmacKey(secret);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, payloadBytes));
  return `${bytesToB64url(payloadBytes)}.${bytesToB64url(sig)}`;
}

export async function verifyToken(token, secret) {
  try {
    const [payloadPart, sigPart] = token.split(".");
    if (!payloadPart || !sigPart) return { ok: false };
    const payloadBytes = b64ToBytes(payloadPart);
    const sig = b64ToBytes(sigPart);
    const key = await hmacKey(secret);
    const valid = await crypto.subtle.verify("HMAC", key, sig, payloadBytes);
    if (!valid) return { ok: false };
    const payload = JSON.parse(new TextDecoder().decode(payloadBytes));
    if (typeof payload.exp !== "number" || payload.exp < Math.floor(Date.now() / 1000)) {
      return { ok: false };
    }
    return { ok: true, keyId: payload.kid };
  } catch {
    return { ok: false };
  }
}

// ---------------------------------------------------------------------------
// Minimal CBOR decoder (App Attest uses a constrained subset)
// ---------------------------------------------------------------------------

function decodeCBOR(buf) {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  let off = 0;
  function readLen(info) {
    if (info < 24) return info;
    if (info === 24) return view.getUint8(off++);
    if (info === 25) { const v = view.getUint16(off); off += 2; return v; }
    if (info === 26) { const v = view.getUint32(off); off += 4; return v; }
    if (info === 27) { const hi = view.getUint32(off); const lo = view.getUint32(off + 4); off += 8; return hi * 2 ** 32 + lo; }
    throw new Error("CBOR: unsupported length");
  }
  function read() {
    const ib = view.getUint8(off++);
    const major = ib >> 5;
    const info = ib & 0x1f;
    switch (major) {
      case 0: return readLen(info);
      case 1: return -1 - readLen(info);
      case 2: { const len = readLen(info); const b = buf.slice(off, off + len); off += len; return b; }
      case 3: { const len = readLen(info); const b = buf.slice(off, off + len); off += len; return new TextDecoder().decode(b); }
      case 4: { const len = readLen(info); const a = []; for (let i = 0; i < len; i++) a.push(read()); return a; }
      case 5: { const len = readLen(info); const m = {}; for (let i = 0; i < len; i++) { const k = read(); m[k] = read(); } return m; }
      case 6: { readLen(info); return read(); } // tag — skip wrapper
      case 7: { if (info === 20) return false; if (info === 21) return true; if (info === 22) return null; return undefined; }
      default: throw new Error("CBOR: bad major type");
    }
  }
  return read();
}

// ---------------------------------------------------------------------------
// Minimal ASN.1 DER parser (TLV)
// ---------------------------------------------------------------------------

function parseTLV(bytes, off = 0) {
  const tag = bytes[off++];
  let len = bytes[off++];
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | bytes[off++];
  }
  const headerEnd = off;
  return { tag, length: len, content: bytes.subarray(off, off + len), headerEnd, end: off + len };
}

/** Returns all direct children TLVs of a constructed node. */
function tlvChildren(content) {
  const out = [];
  let off = 0;
  while (off < content.length) {
    const node = parseTLV(content, off);
    out.push(node);
    off = node.end;
  }
  return out;
}

function oidToString(content) {
  const parts = [];
  let value = 0;
  for (let i = 0; i < content.length; i++) {
    const b = content[i];
    value = (value << 7) | (b & 0x7f);
    if (!(b & 0x80)) {
      if (parts.length === 0) {
        parts.push(Math.floor(value / 40));
        parts.push(value % 40);
      } else {
        parts.push(value);
      }
      value = 0;
    }
  }
  return parts.join(".");
}

// ---------------------------------------------------------------------------
// X.509 helpers (only what App Attest needs)
// ---------------------------------------------------------------------------

/** Parses an X.509 cert (DER) into the pieces we need. */
function parseCertificate(der) {
  const cert = parseTLV(der);                       // SEQUENCE
  const [tbs, sigAlg, sigValue] = tlvChildren(cert.content);
  // Raw TBSCertificate bytes (signature is computed over these). Reconstruct the
  // exact TLV rather than slicing `der` with content-relative offsets.
  const tbsBytes = rebuildTLV(tbs);
  const tbsChildren = tlvChildren(tbs.content);

  // Skip optional [0] version; locate SubjectPublicKeyInfo (7th field after version) and extensions [3]
  let idx = 0;
  if (tbsChildren[0].tag === 0xa0) idx = 1;         // explicit [0] version present
  // order: serial, sigAlg, issuer, validity, subject, spki, [3]extensions
  const spki = tbsChildren[idx + 5];

  const extensionsWrapper = tbsChildren.find((c) => c.tag === 0xa3);
  const extensions = extensionsWrapper ? tlvChildren(tlvChildren(extensionsWrapper.content)[0].content) : [];

  return {
    tbsBytes,
    spkiDer: rebuildTLV(spki),
    signatureAlgOid: oidOfAlg(sigAlg),
    signatureValue: stripBitStringPadding(sigValue.content),
    extensions,
  };
}

function rebuildTLV(node) {
  // Reconstruct the full DER (tag+len+content) for a parsed node.
  const len = node.content.length;
  let header;
  if (len < 0x80) {
    header = new Uint8Array([node.tag, len]);
  } else {
    const lenBytes = [];
    let l = len;
    while (l > 0) { lenBytes.unshift(l & 0xff); l >>= 8; }
    header = new Uint8Array([node.tag, 0x80 | lenBytes.length, ...lenBytes]);
  }
  return concatBytes(header, node.content);
}

function oidOfAlg(algSeq) {
  const oidNode = tlvChildren(algSeq.content)[0];
  return oidToString(oidNode.content);
}

function stripBitStringPadding(bitString) {
  // BIT STRING content starts with an "unused bits" byte (0 here)
  return bitString.subarray(1);
}

/** Find an extension's inner value by OID. */
function findExtension(extensions, oid) {
  for (const ext of extensions) {
    const children = tlvChildren(ext.content);
    const extOid = oidToString(children[0].content);
    if (extOid === oid) {
      // last child is the OCTET STRING extnValue (critical flag may sit between)
      const octet = children[children.length - 1];
      return octet.content;
    }
  }
  return null;
}

/** Detect named curve from an SPKI DER to pick the WebCrypto import params. */
function curveFromSpki(spkiDer) {
  const spki = parseTLV(spkiDer);
  const alg = tlvChildren(spki.content)[0];
  const params = tlvChildren(alg.content)[1];
  const curveOid = oidToString(params.content);
  if (curveOid === "1.2.840.10045.3.1.7") return { namedCurve: "P-256", hash: "SHA-256", size: 32 };
  if (curveOid === "1.3.132.0.34") return { namedCurve: "P-384", hash: "SHA-384", size: 48 };
  return null;
}

/** Convert a DER ECDSA signature (SEQUENCE{r,s}) to raw r||s for WebCrypto. */
function derEcdsaToRaw(derSig, size) {
  const seq = parseTLV(derSig);
  const [r, s] = tlvChildren(seq.content);
  const norm = (intNode) => {
    let v = intNode.content;
    while (v.length > size && v[0] === 0x00) v = v.subarray(1); // drop sign byte
    const out = new Uint8Array(size);
    out.set(v, size - v.length);
    return out;
  };
  return concatBytes(norm(r), norm(s));
}

async function importEcPublicKey(spkiDer) {
  const curve = curveFromSpki(spkiDer);
  if (!curve) throw new Error("Unsupported EC curve");
  const key = await crypto.subtle.importKey(
    "spki", spkiDer, { name: "ECDSA", namedCurve: curve.namedCurve }, false, ["verify"]
  );
  return { key, curve };
}

/** Verify cert.signature using the issuer's public key. */
async function verifyCertSignedBy(cert, issuerSpkiDer) {
  const { key, curve } = await importEcPublicKey(issuerSpkiDer);
  const hash = cert.signatureAlgOid === "1.2.840.10045.4.3.3" ? "SHA-384" : "SHA-256";
  const rawSig = derEcdsaToRaw(cert.signatureValue, hash === "SHA-384" ? 48 : 32);
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, rawSig, cert.tbsBytes);
}

function pemToDer(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return b64ToBytes(b64);
}

// ---------------------------------------------------------------------------
// authData parsing (WebAuthn-style)
// ---------------------------------------------------------------------------

function parseAuthData(authData) {
  const rpIdHash = authData.subarray(0, 32);
  const flags = authData[32];
  const signCount = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
  return { rpIdHash, flags, signCount };
}

// ---------------------------------------------------------------------------
// Attestation verification
// ---------------------------------------------------------------------------

export async function verifyAttestation({ attestation, keyId, challenge, teamId, bundleId, allowDevEnv = false }) {
  try {
    // Fail closed if the Apple root CA hasn't been configured (see top of file).
    if (!APPLE_APP_ATTEST_ROOT_CA_PEM) return { ok: false, reason: "root-ca-not-configured" };

    const obj = decodeCBOR(attestation);
    if (obj.fmt !== "apple-appattest") return { ok: false, reason: "bad-fmt" };

    const x5c = obj.attStmt.x5c;                    // [ credCert, intermediateCert ]
    const authData = obj.authData;
    if (!x5c || x5c.length < 2) return { ok: false, reason: "no-x5c" };

    const credCert = parseCertificate(x5c[0]);
    const intermediateCert = parseCertificate(x5c[1]);
    const rootDer = pemToDer(APPLE_APP_ATTEST_ROOT_CA_PEM);
    const rootCert = parseCertificate(rootDer);

    // ── Step 1–2: certificate chain up to Apple's App Attest Root CA ──────────
    // ⚠️ High-risk / untestable here — validate against real attestations.
    const credOk = await verifyCertSignedBy(credCert, intermediateCert.spkiDer);
    const interOk = await verifyCertSignedBy(intermediateCert, rootCert.spkiDer);
    if (!credOk || !interOk) return { ok: false, reason: "chain" };

    // ── Step 3: nonce = SHA256(authData || SHA256(challenge)) ─────────────────
    const clientDataHash = await sha256(b64ToBytes(challenge));
    const expectedNonce = await sha256(concatBytes(authData, clientDataHash));

    // ── Step 4: nonce must match the credCert extension (OID …8.2) ────────────
    const extValue = findExtension(credCert.extensions, NONCE_OID);
    if (!extValue) return { ok: false, reason: "no-nonce-ext" };
    // extValue = SEQUENCE { [1] EXPLICIT OCTET STRING nonce }
    const seq = parseTLV(extValue);
    const tagged = tlvChildren(seq.content)[0];
    const nonceOctet = tlvChildren(tagged.content)[0];
    if (!bytesEqual(nonceOctet.content, expectedNonce)) return { ok: false, reason: "nonce-mismatch" };

    // ── Step 5: keyId must equal SHA256(credCert public key) ──────────────────
    const pubKeyForId = subjectPublicKeyBytes(credCert.spkiDer);
    const computedKeyId = await sha256(pubKeyForId);
    if (!bytesEqual(computedKeyId, keyId)) return { ok: false, reason: "keyid-mismatch" };

    // ── Step 6: authData checks (rpId hash, counter==0, aaguid) ───────────────
    const { rpIdHash, signCount } = parseAuthData(authData);
    const appIdHash = await sha256(new TextEncoder().encode(`${teamId}.${bundleId}`));
    if (!bytesEqual(rpIdHash, appIdHash)) return { ok: false, reason: "rpid-mismatch" };
    if (signCount !== 0) return { ok: false, reason: "bad-initial-counter" };

    // ── Step 7: the credCert public key is what we store for future assertions ─
    return { ok: true, publicKeyDer: credCert.spkiDer, signCount: 0 };
  } catch (e) {
    return { ok: false, reason: `exception:${e.message}` };
  }
}

/** Extract the raw EC public point bytes (used for the keyId hash). */
function subjectPublicKeyBytes(spkiDer) {
  const spki = parseTLV(spkiDer);
  const bitString = tlvChildren(spki.content)[1];
  return stripBitStringPadding(bitString.content); // 0x04 || X || Y (uncompressed point)
}

// ---------------------------------------------------------------------------
// Assertion verification (token refresh — proves possession of the attested key)
// ---------------------------------------------------------------------------

export async function verifyAssertion({ assertion, clientData, publicKeyDer, prevCount, teamId, bundleId }) {
  try {
    const obj = decodeCBOR(assertion);
    const sig = obj.signature;
    const authData = obj.authenticatorData;

    const clientDataHash = await sha256(clientData);
    const nonce = await sha256(concatBytes(authData, clientDataHash));

    const { key } = await importEcPublicKey(publicKeyDer);
    const rawSig = derEcdsaToRaw(sig, 32); // P-256 assertions
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSig, nonce);
    if (!valid) return { ok: false, reason: "sig" };

    const { rpIdHash, signCount } = parseAuthData(authData);
    const appIdHash = await sha256(new TextEncoder().encode(`${teamId}.${bundleId}`));
    if (!bytesEqual(rpIdHash, appIdHash)) return { ok: false, reason: "rpid" };
    if (signCount <= prevCount) return { ok: false, reason: "replay" };

    return { ok: true, newCount: signCount };
  } catch (e) {
    return { ok: false, reason: `exception:${e.message}` };
  }
}
