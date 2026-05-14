# AI Quota Bar Cloud Sync

This Worker stores quota snapshots in Cloudflare D1. Provider credentials are not uploaded by the app.

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

7. Paste the deployed Worker URL and the same sync token into AI Quota Bar preferences.

## API

- `GET /v1/health`: checks authentication and Worker availability.
- `POST /v1/quota-samples`: stores one refresh snapshot.
- `GET /v1/quota-samples?device_id=...&limit=100`: returns recent samples for inspection.
