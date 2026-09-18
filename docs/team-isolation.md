# Public team isolation / Usage & Team

Implemented boundary:
- Personal use works without a team and performs no shared quota reads/uploads.
- Settings combines local usage, native team create/join, member/device/account usage, quota sharing and sync status.
- Team owners retain the one-time management password and manage invitations/devices/account cleanup in `/team`.
- Platform admins inspect all teams, historical shared data, D1 and deletion audit in `/admin` using an independent session.
- Quota snapshots and consumption events use the same device credential. Provider secrets and conversations are not synced.
- Members of a team can read the team's aggregate usage and quotas. Only the management session can delete an account's quota history.

Data:
- `0007_team_quota.sql` creates new team-scoped snapshots/heads and audit tables without altering legacy data.
- Keys include team, device, provider, account and model. Latest quota is deduplicated across devices; consumption remains an event ledger.
- Retention is 90 days based on server time and runs only in the authenticated team.
- Legacy unscoped outbox files stay quarantined. New local queues and their capacity limits are separated by connection binding.
- Team changes clear cloud caches/status and discard late replies. A leave revokes the device before removing its local connection.
- Existing same-device identity rotation now requires the member passphrase or the current credential, not the device ID alone.

Release order:
1. Back up the database through the existing deployment process.
2. Ensure migrations 0001–0006 have been applied, then apply 0007 (additive, idempotent).
3. Deploy the Worker/assets with the independent platform and provisioning secrets configured.
4. Distribute the new native client. Older shared-token clients receive authorization errors until upgraded and joined.
5. Verify team A/B using identical account/device names, revocation, team deletion, admin login and legacy read-only inspection.

Do not re-enable the legacy shared-token endpoints during rollback. Do not infer historic ownership from email or account name.
Explicit ownership reconciliation/import is a separate operator action; this release preserves old data rather than guessing.
Production migration, deployment and public release are not performed by local tests/builds.
