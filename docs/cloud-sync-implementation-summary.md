# Cloud Sync Implementation Summary

Date: 2026-05-14

## Goal

Preserve AI Quota Bar's important quota history online with a free database, while keeping provider credentials local and secure.

## Implemented Architecture

- Cloud database: Cloudflare D1
- API layer: Cloudflare Worker
- macOS client storage:
  - Provider credentials remain in macOS Keychain.
  - Cloud sync token is stored separately in macOS Keychain.
  - Worker URL and enablement are stored in UserDefaults.

## Cloudflare Resources

- D1 database: `ai-quota-bar`
- Worker: `ai-quota-bar-sync`
- Worker URL: `https://ai-quota-bar-sync.techfanseric.workers.dev`
- Worker secret: `SYNC_TOKEN`
- Local token backup: `cloudflare/.sync-token` (ignored by git)

## App Changes

- Added `CloudSyncService.swift` to upload quota snapshots and test cloud connectivity.
- Extended `KeychainService.swift` to store the cloud sync token.
- Updated `UsageViewModel.swift` to upload a snapshot after each successful refresh.
- Updated `SettingsView.swift` with a Cloud Backup section:
  - enable switch
  - Worker URL
  - sync token
  - test button
- Added localized English and Simplified Chinese cloud-sync copy.

## Worker API

- `GET /v1/health`: authenticated health check.
- `POST /v1/quota-samples`: stores one refresh snapshot.
- `GET /v1/quota-samples?limit=300`: returns recent samples.
- `GET /v1/quota-samples?device_id=...&limit=100`: returns recent samples for one device.
- `GET /v1/devices`: lists synced devices.

## One-Click Data Viewer

Preferred path: open AI Quota Bar Settings, then click **View remote data** in the Cloud Backup section.
The app fetches remote D1 data through the authenticated Worker, generates a local HTML report, and opens it in the browser.

Fallback command:

```bash
open /Users/ericyim/ai-quota-bar/cloudflare/view-remote-data.command
```

The command reads `cloudflare/.sync-token`, calls the deployed Worker with authorization, generates the same kind of local HTML report, and opens it in the browser.

## Verification Completed

- `swift build`
- `node --check cloudflare/src/worker.js`
- Remote D1 schema migration
- Worker deployment
- Authenticated `/v1/health` check
- Remote write/read smoke test
- Smoke test data cleanup
- `make install`

## Security Notes

- MiniMax, GLM, and ChatGPT credentials are not uploaded.
- Cloud data contains quota snapshots only: provider name, account display name, model name, totals, remaining quota, reset times, and detail text.
- The Worker requires Bearer token authentication for every endpoint.
