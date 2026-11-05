# Sync

Date: 2026-11-05. Friends develop on cloud servers and over SSH, and want that usage under one account on their Mac. This is the line. The batch, the machine id and local import exist. Nothing else in this document is built.

## What syncs

- Usage records: source, client, model, provider, time, token counts (input, output, reasoning, cache read, cache write 5m, cache write 1h), the subagent flag, and the speed fields `startTime`, `generationMs` and `speed`.
- The latest quota snapshot of each limit. A newer `observedAt` wins. An older one does not replace it.

## What never syncs

- Project names and paths.
- Prompts, file names, file contents and tool arguments.
- Session ids, raw or buried in a dedup key.
- The live rate, the menu bar figure and tok/min. They stay on the machine that produced them.
- Credentials.

Totals, cost, heatmaps, and model and CLI groupings count every machine once foreign rows exist. Enabled sources still apply. With no foreign rows every figure is unchanged.

## Format

Version 1. One JSON object, so a later mailbox can encrypt these bytes whole:

```json
{
  "version": 1,
  "machine": "A stable random id for this install",
  "events": [],
  "quotas": []
}
```

Times are unix seconds. `machine` is a UUID drawn once and stored in the database. It is not derived from the host name, a serial number or the user name.

`events[].dedupKey` is not the local key. It is the SHA-256 of the machine id, a NUL byte and the raw key, written as 64 lowercase hex digits. The raw key stays in the local store so logs can still be merged. Import stores the hash under the batch's machine id. The same batch a second time changes nothing. A larger `output`, or the same output at a later time, replaces the row, the same rule as local ingest. There is no project, path, prompt, file name or session field on the record, so those cannot be written out.

`quotas[]` carries provider, window, scope, used percent, reset time, observed time, origin and plan.

`tacho-cli export` writes the batch to stdout, or to `--output`. `tacho-cli import` reads stdin, or `--input`. Neither opens a connection. `ssh host tacho-cli export | tacho-cli import` is the whole transfer. Export does not scan; `scan` fills the store first. Import does not scan either.

Rebuilding the index deletes this machine's rows and reads its logs again. Rows from other machines have no logs to reread, so they stay.

Opening a store from the previous schema copies it to `<database>.bak` once, then adds the machine column. Existing rows become this install's. The unique key is machine plus dedup key.

## Mailbox and pairing, later

Each person deploys their own Cloudflare Worker and D1 with a one-click button. The backend is a dumb encrypted mailbox: it cannot read what it holds. Merging happens on the Mac. Devices join with a pairing code, not an account. Until that exists, SSH pull is the path, and it uses no network of Tacho's.

## Not built

- The Worker, D1, the button, pairing, accounts and encryption.
- A Linux app, or a Windows app. The only Linux exception is a headless collector: `tacho-cli` exporting on the other machine.
- Syncing the live rate.
- Putting project names in the batch.
