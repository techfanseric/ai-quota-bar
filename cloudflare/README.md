# AI Quota Bar Cloud Sync Backend

This directory contains the Cloudflare Worker and D1 schema used by AI Quota
Bar's optional cloud sync. The app uploads quota metadata and account labels,
but does not upload MiniMax or Codex provider credentials.

The current public app uses the built-in service endpoint. This backend can be
deployed independently for development; using a private deployment currently
requires changing `CloudSyncSettings` in the app source and rebuilding it.

## Deploy

1. Install and sign in to Wrangler.

```bash
npm install -g wrangler
wrangler login
```

2. Create a free D1 database.

```bash
wrangler d1 create ai-quota-bar
```

3. Copy `wrangler.toml.example` to `wrangler.toml`, then paste the returned `database_id`.

4. Apply the schema.

```bash
wrangler d1 execute ai-quota-bar --file=./schema.sql
```

5. Create a long random token and store it as a Worker secret.

```bash
openssl rand -hex 32
wrangler secret put SYNC_TOKEN
```

6. Deploy.

```bash
wrangler deploy
```

7. For a development build, update `CloudSyncSettings` with the deployed Worker
   URL and token, then rebuild AI Quota Bar.

Do not commit production tokens or a populated `wrangler.toml`.

## API

- `GET /v1/health`: checks authentication and Worker availability.
- `POST /v1/quota-samples`: stores one refresh snapshot.
- `GET /v1/quota-samples?device_id=...&limit=100`: returns the latest sample per model for inspection.
- `GET /v1/quota-samples?history=1&limit=500`: returns refresh-history samples for chart reconstruction.
