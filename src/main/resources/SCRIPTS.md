# Operational Scripts

Utility scripts that live in `docs/`. They are operator tools, not part of any
build — run them by hand against a running environment.

| Script | Purpose | Risk |
|---|---|---|
| [`extract_model_files.py`](#extract_model_filespy) | Pull model binaries out of MongoDB, or decode one from a file | Read-only |
| [`drop_collections.sh`](#drop_collectionssh) | Wipe a tenant's transactional collections | **Destructive** |
| [`refresh-memcached.sh`](#refresh-memcachedsh) | Flush the memcached cache | Disruptive |

Run everything from the repository root (`subledger/`).

---

## Background: how tenants and model files are stored

Two facts explain most of what these scripts do.

**Each tenant is its own MongoDB database.** `MultiTenantMongoDbFactory` uses the
tenant id directly as the database name, falling back to `master` when no tenant
is set. So "which tenant" and "which database" are the same question. On the dev
box today that means `master`, `TNT002`, `TNT003`, `TNT_UABBAS_1`.

**Model files are stored inline as BSON binary.** `ModelFile`
(`common/src/main/java/com/fyntrac/common/entity/ModelFile.java`) holds the file
as an `org.bson.types.Binary` in the `ModelFiles` collection, and `Model.modelFileId`
in the `Models` collection points at it. There is no filesystem copy — the binary
in Mongo *is* the model.

---

## `extract_model_files.py`

Gets model files out of Mongo and onto disk in a form you can open.

Requires `pymongo` (`pip install pymongo`). Mongo's own CLI tools (`mongosh`,
`mongodump`) are **not** required and are not currently installed on the dev box.

### Mode 1 — straight from the database

```bash
# Start here. Read-only: shows what would be extracted, writes nothing.
python3 docs/extract_model_files.py --props --all-tenants --list

# Extract everything into ./model-files/<tenant>/
python3 docs/extract_model_files.py --props --all-tenants --out ./model-files

# A single tenant
python3 docs/extract_model_files.py --props --tenant master --out ./model-files
```

`--props` reads the host and credentials from
`common/src/main/resources/application-dev.properties`, so no password goes on
the command line or into your shell history. For any other environment, supply a
connection instead:

```bash
python3 docs/extract_model_files.py \
  --uri "mongodb://host:27017/?authSource=admin" \
  --username root --password 'secret' \
  --all-tenants --list
```

`--uri` also reads from `$MONGODB_URI`, and `--username`/`--password` from
`$MONGODB_USERNAME`/`$MONGODB_PASSWORD`, if you prefer the environment.

`--all-tenants` discovers tenants by scanning for databases that actually contain
a `ModelFiles` collection, so it picks up new tenants without a code change.

### Mode 2 — from a file, with no database access

Use this when someone hands you a blob, or when the database isn't reachable from
where you are.

```bash
# To a file
python3 docs/extract_model_files.py --input dump.bson --out model.py

# To the terminal
python3 docs/extract_model_files.py --input export.json --out -

# A dump holding several documents → one file per document
python3 docs/extract_model_files.py --input collection.bson --out ./decoded/
```

The input format is **auto-detected** and reported back to you, because the same
binary reaches you in different shapes depending on how it left Mongo:

| Shape | Typical source |
|---|---|
| `.bson` | `mongodump` |
| Extended JSON — `{"fileData": {"$binary": {"base64": "…"}}}` | `mongoexport` (single doc or JSONL; the legacy `{"$binary","$type"}` form works too) |
| base64 text | a blob copied out of a shell or GUI |
| raw bytes | the binary written straight to a file |

If you do have the Mongo tools somewhere, this is how to produce an input file:

```bash
mongodump --uri "mongodb://root:'R3s3rv#313'@127.0.0.1:27017/master?authSource=admin" \
  --collection ModelFiles --out ./dump
python3 docs/extract_model_files.py --input ./dump/master/ModelFiles.bson --out ./decoded/
```

`--input` is self-contained and will refuse to combine with `--props`,
`--tenant`, or `--all-tenants`.

### Options

| Flag | Effect |
|---|---|
| `--list` | Dry run: print what would be extracted, write nothing |
| `--out DIR` | Output location. Online mode defaults to `./model-files` |
| `--overwrite` | Replace existing files instead of appending the file id |
| `--props [FILE]` | Read host/credentials from a Spring properties file |
| `--help` | Full option list |

### How files get named

Online mode joins `Models` → `ModelFiles` on `modelFileId`, so files land under
their model name (`IFRSStage3.py`) rather than a bare ObjectId. Two cases are
called out explicitly rather than hidden:

- a `ModelFile` that no `Model` references is written as `orphan-<id>`
- a file whose `Model` has `isDeleted` set gets a `.deleted` marker in the name

Files never silently overwrite each other: tenants get separate directories, and
a name collision within one tenant gets the file id appended unless you pass
`--overwrite`.

`--input` mode has no `Models` collection to consult, so it names output after
the document `_id` (or the input filename for raw/base64 input). If good names
matter, prefer the online mode.

### Choosing the extension

`contentType` on its own is **not** reliable here: DSL and Python models are
uploaded as `text/plain` even though they are Python source. The script therefore
prefers `Model.modelType` (`EXCEL` / `PYTHON` / `DSL`), cross-checks it against
the file's own magic bytes, and only falls back to `contentType` when that is
specific. This is the same weakness behind the `GET /api/dataloader/model/download/{fileId}`
endpoint returning everything as `downloaded-file.xlsx`.

Not every model has a plain-text form — an `EXCEL` model is a zip container. When
a payload isn't valid UTF-8 the script says so, writes the raw bytes instead of
corrupting them, and refuses to dump binary to stdout.

### Output is tenant data

`model-files/` is gitignored. The extracted files are customer model source —
keep them out of commits and off shared drives.

---

## `drop_collections.sh`

> **Destructive and irreversible.** Drops transactional collections outright.
> There is no confirmation prompt and no backup. Never point it at production.

Resets a tenant to a clean state for a reload — activity, balances, ledger
entries, events, and instrument attributes all go.

```bash
./docs/drop_collections.sh <database-name>

# e.g.
./docs/drop_collections.sh TNT002
```

**Always pass the database name.** The script takes it as `$1` and does not
validate it; with no argument `mongosh` falls back to its own default database,
so you get no useful error — just a run that silently did nothing you wanted.

It drops: `EventHistory`, `InstrumentActivityReplayState`,
`InstrumentActivityState`, `ExecutionState`, `GeneralLedgerEntery`,
`GeneralLedgerAccountBalance`, `Batch`, `sequences`,
`GeneralLedgerAccountBalanceStage`, `GeneralLedgerEnteryStage`, `ReclassValues`,
`MetricLevelLtd`, `AttributeLevelLtd`, `InstrumentLevelLtd`, `InstrumentAttribute`,
`TransactionActivity`.

(The array in the script has a stray trailing space in `"InstrumentLevelLtd "`.
It is harmless — `db.InstrumentLevelLtd .drop()` is still valid JavaScript, so the
collection does get dropped — but worth tidying if you edit the list.)

Note what it does **not** touch: `Models`, `ModelFiles`, `EventConfiguration`,
and the custom-table definitions survive, so configuration and uploaded models
outlive the wipe.

Requirements: a running `mongodb` Docker container (the name is hardcoded), with
`mongosh` available inside it. Credentials are hardcoded in the script.

---

## `refresh-memcached.sh`

Flushes everything in memcached. Use it when cached tenant state has gone stale
relative to the database — typically right after `drop_collections.sh`.

```bash
./docs/refresh-memcached.sh
```

It checks the container is running and prompts for confirmation before flushing.
The cache is shared across tenants, so a flush affects everyone on that instance;
expect a burst of cache misses immediately afterwards.

Requirements: a running `memcached` Docker container (the name is hardcoded).

---

## Credentials

The dev credentials (`root` / `R3s3rv#313`) are committed in
`common/src/main/resources/application-dev.properties`, `application-test.properties`,
`tenant/src/main/resources/application.properties`, and the docker-compose file,
and are hardcoded in `drop_collections.sh`.

That is workable for a local docker stack but means these values must be treated
as compromised for any shared or production environment — they are in git history
and readable by anyone with repo access. Use real secrets there, passed via
`--uri` / `--username` / `--password` or the matching environment variables,
never committed.
