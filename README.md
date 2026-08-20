# DocumentBrain

DocumentBrain is an iOS app for **organizing documents and asking questions about their content** using on-device semantic search and a conversational AI assistant.

You import files, the app extracts text, splits it into semantic chunks, generates vector embeddings, and then answers your questions in a chat interface with citations back to the source document. Invoices, boarding passes, tickets and contracts are automatically analysed to extract structured data — vendor, amount, flight route, seat, event details — which you can add to your calendar in one tap. Any QR/barcodes are detected so you can display them at full brightness directly from the app, and a full-text search lets you find the exact fragment of any document instantly.

---

## Problem

When your information is scattered across PDFs, document photos, spreadsheets and text files, retrieving a specific answer means opening multiple files and searching manually.

DocumentBrain lets you:

- centralize all your files in an organized library,
- group them in hierarchical folders,
- query the content in natural language from a chat interface,
- see exactly which fragment of which document each answer came from.

---

## Features

### Library & organization

- Import from the file system, camera/gallery, and Share Extension.
- **Hierarchical folders** with breadcrumb navigation, create, rename, delete, and move documents to any depth level.
- Document cards with thumbnail, processing status, and a retry action on error.
- Filters and sorting by name, date, and type.

### Document processing

- **Automatic pipeline**: text extraction → semantic chunking → embeddings → structured metadata → barcode detection → persistence.
- **Retry with exponential backoff** (up to 3 attempts, 2s and 4s delays) for transient errors.
- **Crash recovery on startup**: detects documents stuck in intermediate states and reprocesses them automatically.
- **Full reindex** with progress overlay; triggered automatically when an embedding model version change is detected.
- **Background metadata sweep**: on every launch, any ready document without structured metadata gets analysed automatically in the background.

### Structured metadata extraction

DocumentBrain analyses each document and extracts structured fields depending on the document type:

| Type | Fields extracted |
|---|---|
| Invoice / receipt | Vendor, date, amount, currency, category |
| Flight / boarding pass | Airline, origin → destination, flight number, departure & arrival time, seat |
| Concert / event ticket | Event title, venue, date, time, seat |
| Contract / payslip / statement | Vendor, date, amount |

- **Two-tier extraction**: Gemini (via the Cloudflare Worker proxy) is used first for best quality; when there is no network or the proxy is unconfigured, the app falls back to **Apple Foundation Models** on-device (iOS 26+), which fills a type-safe `@Generable` struct directly — no JSON parsing or truncation issues, and works fully offline at no cost.
- **Contextual UI**: the detail card adapts its layout and labels to the document type (e.g. "Airline" instead of "Vendor" for flights, route row with arrow for origin → destination).
- **Vision OCR supplement**: PDF pages with fewer than 500 PDFKit characters also receive a Vision OCR pass, capturing visual-only elements like boarding pass card fields that PDFKit misses.
- **Robust parsing**: the Gemini path tolerates code-fenced JSON, prose preambles, and truncated responses by scanning for the outermost `{…}` block.
- Manual re-extraction available via the ↺ button on the metadata card.

### Add to Calendar

- Whenever a document yields a date, the metadata card shows an **"Añadir al Calendario"** button.
- Tapping it opens the native iOS event editor (`EKEventEditViewController`) pre-filled from the extracted fields:
  - **Flights**: title `Airline · Origin → Destination · Flight no.`, departure/arrival as start/end times (overnight arrivals roll to the next day), seat in the notes.
  - **Events**: title from the event name, venue as the location.
  - **Other documents**: an all-day event on the document date.
- Requests **write-only** calendar access on iOS 17+ (full access on iOS 16); if denied, an alert offers a shortcut to Settings.

### Barcode & QR detection

- **Automatic during ingestion**: `VNDetectBarcodesRequest` scans the first three pages of PDFs and full images.
- **Background sweep on launch**: documents imported before this feature existed get scanned automatically.
- **Smart display**: barcode payloads are classified —
  - IATA BCBP boarding passes → PDF417 regenerated at full screen brightness for gate scanning.
  - URLs → direct "Open in Safari" link.
  - Generic QR codes → QR image at full screen brightness.

### Semantic search

- **Hybrid search**: vector cosine similarity + FTS5 keyword search, merged with chunk-ID deduplication.
- **Score formula**: `0.65·semantic + 0.20·lexical coverage + keyword bonus + entity bonus`. Semantic similarity is the dominant signal; purely semantic matches below 0.50 with no keyword or proper-noun hit are filtered out.
- **Entity detection**: proper nouns (words capitalised in the original query — names, companies, places, flight numbers) get a relevance boost without relying on a hand-maintained word list.
- Context expansion: retrieved chunks are enriched with their neighboring fragments to provide more context to the LLM.
- Short query expansion for conversational follow-ups ("and the author?").

### Full-text content search

- The **library search bar** searches inside document content via FTS5, not just titles.
- Results show the **exact fragment** where the match appears, with the query terms highlighted in the accent color and a window centered on the first hit.
- One best match per document, searched globally across every folder, with a 300 ms debounce; tapping a result opens the document detail.

### Conversational chat

- Multi-turn context: the last 3 conversation rounds are passed to the LLM for coherent responses.
- **Token-by-token streaming**.
- **Full markdown**: headers, lists, code blocks, horizontal rules.
- **Tappable citations**: each answer shows source pills; tapping opens the exact retrieved fragment.
- Text selection on assistant messages (long-press to copy).
- Automatic fallback: Gemini Flash → Apple Intelligence (on-device, iOS 26+) → local extractive answer.
- Automatic disambiguation when retrieved chunks span multiple distinct documents.

### Settings & maintenance

- Language switch (ES / EN) in real time.
- Active AI provider status.
- iCloud sync status.
- Reindex with progress bar.
- Full data wipe (documents, conversations, thumbnail cache).
- **RAG debug panel** (Developer toggle): shows retrieved chunks with scores, expanded query and active provider below each answer.

---

## Supported file types

| Format | Extraction |
|---|---|
| `PDF` | Native text (PDFKit) + Vision OCR supplement for visual-only pages (e.g. boarding pass cards) |
| Images (`jpg`, `png`, `heic`, `webp`…) | OCR via Vision framework |
| `DOCX` | Internal XML parsing |
| `XLSX` | Sheet and shared-strings parsing |
| `TXT`, `MD`, `CSV`, `RTF` | Direct read |
| `ZIP` | Decompression and recursive content processing |

---

## Architecture

### Folder structure

```text
DocumentBrain.xcodeproj/
DocumentBrain/                        # Main app target
├── DocumentBrainApp.swift            # Entry point: startup, onboarding, SyncCoordinator
├── Core/
│   ├── Models/                       # Domain entities
│   ├── Database/                     # Persistence layer (GRDB/SQLite)
│   ├── Services/                     # Business logic
│   ├── Sync/                         # iCloud sync (CKSyncEngine)
│   └── Theme.swift                   # Colors, styles and UI constants
├── Features/                         # SwiftUI screens + ViewModels (MVVM)
│   ├── Library/
│   ├── DocumentDetail/
│   ├── Chat/
│   ├── Settings/
│   ├── Onboarding/
│   └── Import/
├── AI/                               # Tokenizer and vector math
├── PrivacyInfo.xcprivacy             # Privacy Manifest (App Store)
└── Assets.xcassets/
DocumentBrainShareExtension/          # Share Extension target
DocumentBrainTests/                   # Unit tests
cloudflare-worker/                    # Edge proxy (Cloudflare Workers)
```

### Design patterns

- **MVVM**: each feature has a `View` (pure SwiftUI, no business logic) and a `ViewModel` (`@MainActor`, `ObservableObject`).
- **Controlled singletons**: `EmbeddingService.shared` and `QAService.shared` avoid reloading CoreML models on every operation.
- **Dependency injection**: `EmbeddingServiceProtocol` allows mocking embeddings in tests without loading the model.
- **Repository pattern**: each entity has its own repository encapsulating all GRDB queries. Raw SQL interpolation is never done outside repositories.

---

## Design decisions

Notable trade-offs, and why they were made this way rather than the more obvious alternative.

| Decision | Why |
|---|---|
| **On-device embeddings (CoreML MiniLM)** instead of an embeddings API | Zero marginal cost per query, works fully offline, and no document text ever needs to leave the device to be indexed. Trade-off: the model ships in the binary (~90 MB) and can't be improved server-side without an app update. |
| **Hybrid search (vector + FTS5)** instead of pure vector search | Pure semantic search misses exact-term queries — flight numbers, names, invoice IDs — that a user expects to just work. A weighted merge (`0.65·semantic + 0.20·lexical + bonuses`) fixes recall on those without standing up a separate reranking service. |
| **Three-tier LLM fallback** (Gemini → on-device Foundation Models → local extractive answer) instead of a single provider | The app never goes fully mute: no network degrades to on-device generation, no Apple Intelligence degrades to a still-useful extracted fragment. Each tier is strictly cheaper/more available than the one above it. |
| **Durable Objects for rate limiting** instead of Workers KV | Quota counters need strong consistency — KV is eventually consistent, so concurrent requests from the same device could race past a limit before a write propagates. DOs serialize access per key, so the counter can't be raced. |
| **Layered abuse defense shipped incrementally** (per-IP cap → App Attest device identity → global ceiling), gated by a `REQUIRE_ATTESTATION` flag | Per-IP limiting protects the proxy from day one with zero client changes. App Attest is a staged rollout specifically so a client/server version mismatch during deployment can't lock out the live app — untokened requests degrade gracefully until the flag is flipped. |
| **API key isolation via a Cloudflare Worker proxy** instead of calling Gemini directly from the client | The Gemini key never ships in the app binary. Worst case if the binary is reverse-engineered: an attacker recovers the app's shared secret, which at most grants access to the proxy (billed, rate-limited, revocable) — never the underlying API key. |
| **MVVM + protocol-based dependency injection** instead of ViewModels owning concrete services | `EmbeddingServiceProtocol` lets ViewModel tests run against a mock instead of loading the real CoreML model, which keeps the 75-test suite fast enough to run on every change instead of being skipped. |
| **GRDB over CoreData** | Needed direct SQL control for FTS5 virtual tables and a hand-tuned bounded-priority-queue vector search — both awkward to express through CoreData's object graph. |

---

## RAG Pipeline

```
INGESTION
─────────────────────────────────────────────────────────────────────
File  →  TextExtractionService  →  plain text
               ↓ up to 3 retries (backoff 2s / 4s)
         ChunkingService  →  semantic fragments (~800 chars / ~200 tokens)
               ↓
         EmbeddingService  →  384-dim vector (multi-qa-MiniLM-L6-cos-v1, CoreML)
               ↓
         ChunkRepository  →  SQLite + FTS5 index

QUERY
─────────────────────────────────────────────────────────────────────
User question
    ↓
expandedQuery (adds context from prior turns if question is short)
    ↓
BERTTokenizer  →  384-dim query vector
    ↓
hybridSearch:
    ├─ vectorSearch   (cosine ≥ 0.15, top-5)
    └─ FTS5 search    (strict AND, relaxed to OR if < 2 results)
    ↓ deduplication + score merge
expandContextWithNeighbors  →  ± 1 neighboring chunk for richer LLM context
    ↓
QAService  →  buildContextPrompt  →  last 3 history turns
    ↓
    1. GeminiQAProvider   (cloud, streaming, multi-turn)
    2. FoundationModelQAProvider  (on-device, Apple Intelligence, iOS 26+)
    3. Extractive answer  (local fragment, no LLM)
    ↓
Answer with full markdown + tappable citations
```

### Semantic chunking

`ChunkingService` splits text while respecting the document's semantic structure:

1. **Normalization**: removes redundant whitespace and collapses excessive blank lines.
2. **Paragraph-first splitting**: paragraphs are the primary split unit.
3. **Orphan paragraph merging**: paragraphs shorter than 60 chars are merged into the next one.
4. **Chunk assembly**: paragraphs are accumulated up to ~800 chars (~200 tokens). Paragraphs that exceed the limit are split at sentence boundaries with abbreviation guards.
5. **Semantic overlap**: the last complete paragraph of the previous chunk is prepended to the next one to avoid context loss at boundaries.

This approach outperforms fixed-size chunking because each fragment tends to contain a coherent idea, improving embedding quality and retrieval precision.

### Embedding model

`multi-qa-MiniLM-L6-cos-v1` (384 dimensions, quantized to CoreML):

- Fine-tuned specifically for Q&A retrieval on question-answer pairs, unlike general-purpose sentence transformers.
- 6-layer transformer, efficient on Apple Neural Engine.
- Cosine-normalized: all vectors are stored with unit norm so dot product equals cosine similarity, making search faster.
- When a model version change is detected at startup, the app triggers a full automatic reindex with progress overlay.

---

## Security

Security is a first-class design concern, not an afterthought. Here is a detailed breakdown of each layer.

### Proxy architecture (API key never on device)

Gemini requests never leave the device directly. The app communicates exclusively with a **Cloudflare Worker** deployed at the edge acting as a secure proxy:

```
iOS App  ──(HTTPS + x-app-secret)──▶  Cloudflare Worker  ──(x-goog-api-key)──▶  Gemini API
```

- The Gemini key (`GEMINI_API_KEY`) lives as an **environment secret** in Cloudflare Workers and never touches the user's device.
- The app authenticates with the Worker using a **shared secret** (`x-app-secret`) HTTP header, stored locally in `Config.plist` (excluded from version control).
- Any request without the correct header receives `401 Unauthorized`.

**Why this matters:** if the app binary were reverse-engineered, an attacker would obtain no API key — only the app secret, which at worst grants access to the proxy (no direct cost to the attacker, billed to your Gemini account).

### Cloudflare Worker — technical details

The Worker (`cloudflare-worker/src/index.js`) implements:

| Mechanism | Implementation |
|---|---|
| App authentication | `x-app-secret` header validated against the `APP_SECRET` environment variable (first gate, every route) |
| Device attestation | Apple App Attest: the app proves it is a genuine instance via the `/attest/*` endpoints and receives a short-lived HMAC session token; enforced on `/chat` when `REQUIRE_ATTESTATION` is enabled |
| Rate limiting | Strongly-consistent Durable Objects: per-IP (100/day), per-attested-device (50/day) and a global ceiling (5000/day); each returns `429` |
| Key injection | `x-goog-api-key` header added server-side, never exposed to the client |
| SSE streaming | Direct pass-through of Gemini's response body with CORS headers |
| CORS | Restricted to the methods and headers used by the app (`POST`, `x-app-secret`, `Authorization`) |

See [`cloudflare-worker/APP_ATTEST.md`](cloudflare-worker/APP_ATTEST.md) for the attestation flow and staged rollout. The per-IP and global limits are active on deploy without App Attest; the per-device limit and unauthorized-client blocking require the attestation rollout.

### Local persistence

- **GRDB/SQLite with parameterized queries**: the entire database layer uses GRDB's binding API. The library does not allow free-form SQL string interpolation, making SQL injection structurally impossible.
- **FTS5**: `sanitizeFTSQuery` filters and escapes user terms before building the FTS query, preventing index manipulation.
- **No sensitive data in UserDefaults**: no key, token or credential is ever stored in UserDefaults or iCloud key-value storage.
- User files are stored in the app sandbox (`Documents/files`) under standard iOS permissions.

### Config.plist and secrets

`Config.plist` (containing `WorkerURL` and `AppSecret`) is in `.gitignore` and **never committed to the repository**. Each project installation requires creating this file manually (or via CI secrets injection).

### Privacy Manifest (App Store)

`PrivacyInfo.xcprivacy` explicitly declares:

- `NSPrivacyTracking: false` — the app performs no tracking of any kind.
- `NSPrivacyTrackingDomains: []` — no tracking domains.
- `NSPrivacyCollectedDataTypes: []` — no user data is collected.
- `NSPrivacyAccessedAPITypes`:
  - **UserDefaults** (reason CA92.1): stores user preferences (language, onboarding state).
  - **FileTimestamp** (reason C617.1): accesses modification dates of sandbox files.

### Accessibility

All interactive controls have VoiceOver labels and meet Apple HIG's minimum 44×44 pt touch target. Decorative icons are marked `accessibilityHidden(true)`.

---

## AI & privacy

`QAService` implements a provider fallback chain:

| Priority | Provider | Requirements | Characteristics |
|---|---|---|---|
| 1 | **Gemini Flash** (cloud) | Internet connection | Best quality, streaming, multi-turn |
| 2 | **Apple Foundation Models** (on-device) | iOS 26+, Apple Intelligence enabled | Offline, full privacy, no cost |
| 3 | **Extractive answer** (local) | None | Returns the most relevant fragment without an LLM |

- The response language follows the active app language (`AppLanguage`): the system prompt is generated in the selected language.
- Conversational history (last 3 turns) is passed to the LLM for coherent multi-question conversations.
- When retrieved results span multiple documents, the prompt instructs the LLM to disambiguate rather than blend answers.

**Structured metadata extraction** uses the same philosophy with its own two-tier chain: Gemini first for quality, Apple Foundation Models on-device as an offline fallback (iOS 26+). No document content is ever sent anywhere except through the authenticated Cloudflare proxy to Gemini.

---

## iCloud Sync

DocumentBrain includes bidirectional sync with CloudKit (user's private database):

- Syncs documents, folders, conversations, and messages.
- Maintains a local pending-changes queue with retry when the app becomes active.
- `SyncCoordinator` (iOS 17+) orchestrates sync; on iOS 16 the app works fully offline.
- Sync status is visible in Settings (active / syncing / error indicator).

**Requirements**: iOS 17+, active iCloud session, same Apple ID across devices.

---

## Share Extension

`DocumentBrainShareExtension` lets users save content from any app without opening DocumentBrain:

1. From Safari, Mail, WhatsApp or any other app: Share → **Save to DocumentBrain**.
2. The extension copies shared files to the App Group inbox (`group.com.documentbrain.shared`).
3. When DocumentBrain activates, `SharedInboxImporter` detects the inbox and launches the normal pipeline (extraction → chunking → embeddings).

Supports file attachments, URLs, and shared plain text.

---

## Tech stack

| Category | Technology |
|---|---|
| UI | SwiftUI, NavigationStack, TabView |
| Persistence | GRDB 6 (SQLite), FTS5 |
| Semantic search | CoreML, `multi-qa-MiniLM-L6-cos-v1` (384-dim) |
| Tokenization | BERT WordPiece (custom vocab) |
| Cloud LLM | Gemini Flash 2.5 via Cloudflare Worker proxy |
| On-device LLM | Apple Foundation Models (iOS 26+) |
| Text extraction | PDFKit, Vision (OCR + barcode detection), ZIPFoundation |
| Barcode generation | Core Image (PDF417 for boarding passes, QR for generic codes) |
| Metadata extraction | Gemini Flash (cloud) with Apple Foundation Models `@Generable` on-device fallback (iOS 26+) |
| Calendar | EventKit / EventKitUI (`EKEventEditViewController`) |
| Sync | CloudKit / CKSyncEngine (iOS 17+) |
| Edge proxy | Cloudflare Workers (JavaScript) |
| Minimum iOS | iOS 16 |

---

## Local development

### Requirements

- macOS with Xcode 16+.
- iOS Simulator or physical device.
- `Config.plist` with environment keys (see below).

### Config.plist

Create `DocumentBrain/Config.plist` (not included in the repo):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>WorkerURL</key>
    <string>https://your-worker.workers.dev</string>
    <key>AppSecret</key>
    <string>your-shared-secret</string>
</dict>
</plist>
```

### Cloudflare Worker (optional for local development)

```bash
cd cloudflare-worker
npm install -g wrangler
wrangler login

# Set production secrets
wrangler secret put GEMINI_API_KEY
wrangler secret put APP_SECRET

# Deploy
wrangler deploy
```

### Build & test

```bash
# List available schemes
xcodebuild -list -project DocumentBrain.xcodeproj

# Run unit tests
xcodebuild test \
  -project DocumentBrain.xcodeproj \
  -scheme DocumentBrain \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.0'
```

---

## Tests

75 unit tests across 12 test classes in `DocumentBrainTests/`:

| Class | Tests | Coverage |
|---|---|---|
| `VectorMathTests` | 5 | Cosine similarity, vector norm and arithmetic |
| `VectorRoundTripTests` | 3 | Float ↔ Data round-trips |
| `FileTypeDetectionTests` | 13 | Extension detection for all supported formats |
| `ProcessingStatusTests` | 2 | Status enum transitions |
| `CleanedDocumentTitleTests` | 8 | Title sanitisation including known edge cases |
| `ChunkingServiceTests` | 10 | Paragraph splitting, overlap, orphan merging |
| `ChunkRepositoryFTSTests` | 8 | FTS5 index CRUD with in-memory database |
| `QAServicePromptTests` | 5 | Context prompt assembly and history injection |
| `StringSearchTests` | 5 | Search normalisation and head+tail truncation |
| `StructuredDocumentDataTests` | 7 | Amount/date formatting, emptiness, travel classification |
| `ContentSearchResultTests` | 5 | Snippet windowing, centering, ellipses, accent preservation |
| `BarcodeKindTests` | 4 | BCBP / URL / generic barcode classification |

Protocol-based injection of `EmbeddingServiceProtocol` makes ViewModel tests deterministic and fast (no CoreML model loaded in tests).

---

## Status

The full end-to-end flow is implemented and working:

**ingestion → semantic indexing → folder organization → conversational chat with citations → structured metadata → barcode/QR display → calendar events → full-text content search**

Potential next areas:

- Tune hybrid search weights (vector vs. FTS5) with a labelled test collection to optimize recall/precision on large document sets.
- Lightweight cross-encoder re-ranking of retrieved chunks before passing them to the LLM.
- Auto-summary of long documents on import.
