# Privacy Policy — DocumentBrain

**Last updated: August 26, 2026**

DocumentBrain ("the app") is an iOS/macOS app for organizing personal documents and asking questions about their content. This page explains what happens to your data when you use it.

## The short version

- Your documents are stored **on your device**, not on a server we run.
- We don't have user accounts, we don't run analytics or advertising SDKs, and we don't track you across apps or websites.
- The only data that ever leaves your device is (a) an optional iCloud sync to **your own** private iCloud account, and (b) the specific text needed to answer a question or extract structured data, sent to Google's Gemini API through a proxy we operate — and only when you actively use those AI features.

## What's stored, and where

| Data | Where it lives | Who can access it |
|---|---|---|
| Document files, extracted text, search index | Your device's local app storage (sandboxed) | Only you, only on your device |
| Conversations and chat history | Your device's local app storage | Only you, only on your device |
| iCloud sync copy (if enabled) | Your private CloudKit database | Only you, via your Apple ID — we have no access to it |
| App preferences (language, onboarding state) | `UserDefaults` on your device | Only you, only on your device |

We do not operate a backend database of our own. There is no DocumentBrain account, login, or user profile — nothing to tie your usage to an identity we control.

## AI features and Google Gemini

When you ask a question in chat, or when the app automatically extracts structured data from a document (vendor, amount, flight details, etc.), the relevant document text is sent to **Google's Gemini API** to generate the response. This request is routed through a proxy we operate (a Cloudflare Worker), which:

- injects our API key server-side, so it's never embedded in the app,
- authenticates the request as coming from a genuine copy of the app (via Apple's App Attest),
- and does not log or store the document content it forwards — it passes the request through and returns the response.

This only happens when you use a feature that requires cloud AI. You can avoid it entirely:

- **On-device fallback**: if there's no network connection, or on supported devices with Apple Intelligence enabled, the app answers using Apple's on-device Foundation Models instead — nothing leaves your device.
- **Fully local mode**: if no AI provider is available, the app falls back to returning the most relevant excerpt from your own documents directly, with no LLM involved at all.

Data sent to Google is subject to [Google's Gemini API terms and privacy commitments](https://ai.google.dev/gemini-api/terms). We do not sell, share, or use this data for any purpose beyond generating the response you asked for.

## What we don't do

- No advertising or analytics SDKs.
- No tracking of you across other companies' apps or websites.
- No sale of personal data, ever.
- No collection of contacts, precise location, health data, or browsing history — the app has no access to any of these.

The app's [Privacy Manifest](DocumentBrain/PrivacyInfo.xcprivacy) — the machine-readable declaration Apple requires and verifies at build time — states this formally: `NSPrivacyTracking: false`, no tracking domains, no collected data types.

## Permissions the app requests

| Permission | Why | When it's accessed |
|---|---|---|
| Camera | To scan and save a physical document as a photo | Only when you tap the scan/camera button |
| Calendar (write) | To add an event from a date found in a document (flight, appointment, etc.) | Only when you tap "Add to Calendar" |

Neither permission is used for anything beyond the action you explicitly took.

## Deleting your data

You can delete individual documents at any time from the library. Settings also offers a full data wipe, which removes all documents, conversations, and cached thumbnails from your device; if iCloud sync is enabled, the deletion is queued and propagates to your private iCloud database the next time the app syncs.

## Children's privacy

DocumentBrain is not directed at children and does not knowingly collect information from children.

## Changes to this policy

If this policy changes, the "Last updated" date above will change accordingly. Material changes will be reflected in the app's release notes.

## Contact

Questions about this policy or your data can be sent to: **jorgeperez1797@gmail.com**
