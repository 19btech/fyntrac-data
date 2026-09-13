#!/usr/bin/env python3
"""
Extract the model binaries stored in MongoDB out to local disk.

Model files are stored inline as a BSON Binary in the `ModelFiles` collection
(see common/src/main/java/com/fyntrac/common/entity/ModelFile.java); the
`Models` collection references them via `Model.modelFileId`. Each tenant is its
own database (MultiTenantMongoDbFactory uses the tenantId as the database name),
with `master` as the default.

This joins Models -> ModelFiles so the extracted files land under their model
name rather than a bare ObjectId, and falls back to the raw id for orphaned
ModelFiles that no Model points at.

There are two modes:

  * online  — connect to Mongo and pull the binaries out (--props / --uri)
  * offline — decode a binary someone handed you as a file (--input), with no
              database access at all. The input can be a .bson from mongodump,
              mongoexport Extended JSON, a base64 blob, or the raw bytes; the
              format is auto-detected.

Usage:
    # offline: turn a binary file into plain text
    ./extract_model_files.py --input model.bson --out model.py
    ./extract_model_files.py --input export.json --out -        # to stdout

    # see what's there without writing anything
    ./extract_model_files.py --list

    # pull every tenant's files into ./model-files/<tenant>/
    ./extract_model_files.py --all-tenants --out ./model-files

    # a single tenant
    ./extract_model_files.py --tenant fyntrac --out ./model-files

Connection comes from --uri, else $MONGODB_URI, else a local dev default.
Credentials are never written to disk or echoed back.
"""

import argparse
import base64
import binascii
import json
import os
import re
import string
import sys
from urllib.parse import quote_plus

try:
    import bson
    from pymongo import MongoClient
    from pymongo.errors import OperationFailure
except ImportError:
    sys.exit("pymongo is required:  pip install pymongo")

DEFAULT_URI = "mongodb://127.0.0.1:27017/?authSource=admin&directConnection=true"

# The project's own dev settings, relative to this script (docs/ -> repo root).
DEFAULT_PROPS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "common", "src", "main", "resources", "application-dev.properties")

# Databases that are never tenants.
SYSTEM_DBS = {"admin", "local", "config"}

MODEL_FILES = "ModelFiles"
MODELS = "Models"

# contentType -> extension, for the types this system actually stores.
CONTENT_TYPE_EXT = {
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.ms-excel": ".xls",
    "application/vnd.ms-excel.sheet.macroenabled.12": ".xlsm",
    "text/x-python": ".py",
    "text/x-python-script": ".py",
    "application/x-python-code": ".py",
    "application/json": ".json",
    "application/zip": ".zip",
}

# The stored contentType is not trustworthy on its own: DSL and Python models are
# uploaded as "text/plain" even though they are Python source. Treat these as "no
# real information" and decide from Model.modelType / the file's own bytes instead.
GENERIC_CONTENT_TYPES = {"", "text/plain", "application/octet-stream"}

# Model.modelType is the most reliable signal we have.
MODEL_TYPE_EXT = {
    "EXCEL": ".xlsx",
    "PYTHON": ".py",
    "DSL": ".py",
}


def sniff_extension(data: bytes) -> str:
    """Best-effort extension from the leading bytes, when contentType is useless."""
    if data[:4] == b"PK\x03\x04":
        return ".xlsx"          # OOXML is a zip; xlsx is what this system stores
    if data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        return ".xls"           # legacy OLE2 compound document
    head = data[:4096]
    if b"\x00" not in head:
        try:
            text = head.decode("utf-8")
        except UnicodeDecodeError:
            return ".bin"
        if re.search(r"^\s*(import |from \S+ import |def |class )", text, re.M):
            return ".py"
        return ".txt"
    return ".bin"


def extension_for(content_type: str, model_type: str, data: bytes) -> str:
    """Pick an extension: real contentType > modelType > the bytes themselves."""
    normalized = (content_type or "").strip().lower()
    if normalized and normalized not in GENERIC_CONTENT_TYPES:
        ext = CONTENT_TYPE_EXT.get(normalized)
        if ext:
            return ext

    sniffed = sniff_extension(data)

    ext = MODEL_TYPE_EXT.get((model_type or "").strip().upper())
    if ext:
        # Only trust modelType when the bytes don't contradict it — a model row
        # mislabelled EXCEL should still land as .py if it's plainly Python source.
        if ext == ".xlsx" and sniffed in (".xlsx", ".xls"):
            return sniffed
        if ext == ".py" and sniffed in (".py", ".txt"):
            return ".py"
        return ext

    return sniffed


def safe_name(name: str) -> str:
    """Make a model name safe to use as a filename."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", (name or "").strip()).strip("._-")
    return cleaned or "unnamed"


def raw_bytes(file_data):
    """ModelFile.fileData is a BSON Binary; pymongo hands it back as bytes."""
    if file_data is None:
        return None
    if isinstance(file_data, (bytes, bytearray)):
        return bytes(file_data)
    # pymongo Binary subclasses bytes, but guard against a driver returning a wrapper
    return bytes(getattr(file_data, "data", file_data))


def load_properties(path):
    """Pull spring.data.mongodb.* settings out of an application properties file.

    Only the keys this script needs are read. Java properties treat '#' as a
    comment marker at the start of a line only, so a password containing '#'
    mid-value (as the dev one does) survives correctly.
    """
    wanted = ("host", "port", "username", "password", "authentication-database")
    values = {}
    with open(path) as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", "!")) or "=" not in stripped:
                continue
            key, _, value = stripped.partition("=")
            key = key.strip()
            for name in wanted:
                if key == f"spring.data.mongodb.{name}":
                    values[name] = value.strip()
    return values


def uri_from_properties(path):
    props = load_properties(path)
    host = props.get("host", "127.0.0.1")
    port = props.get("port", "27017")
    auth_db = props.get("authentication-database", "admin")
    user = props.get("username")
    password = props.get("password")

    # The properties files point at the docker service name; from the host that
    # is not resolvable, so fall back to localhost.
    if host == "mongodb":
        host = "127.0.0.1"

    creds = ""
    if user:
        creds = quote_plus(user)
        if password:
            creds += ":" + quote_plus(password)
        creds += "@"

    return (f"mongodb://{creds}{host}:{port}/"
            f"?authSource={auth_db}&directConnection=true")


# ══════════════════════════════════════════════════════════════════════════════
# Offline mode: decode a binary that was handed to us as a file, no DB needed.
#
# The same ModelFile binary reaches you in different shapes depending on how it
# left Mongo, so all of them are accepted and auto-detected:
#   * .bson         — mongodump output
#   * Extended JSON — mongoexport, {"fileData": {"$binary": {"base64": "..."}}}
#                     (both the modern and the legacy {"$binary","$type"} form)
#   * base64 text   — a blob copied out of a shell or GUI
#   * raw bytes     — the binary written straight to a file
# ══════════════════════════════════════════════════════════════════════════════

BASE64_CHARS = set(string.ascii_letters + string.digits + "+/=\r\n \t")


def _walk_for_binaries(node, results, label):
    """Collect every $binary / bytes value in a decoded JSON or BSON structure."""
    if isinstance(node, dict):
        # Extended JSON, modern form: {"$binary": {"base64": "...", "subType": "00"}}
        binary = node.get("$binary")
        if isinstance(binary, dict) and "base64" in binary:
            results.append((label, base64.b64decode(binary["base64"])))
            return
        # Extended JSON, legacy form: {"$binary": "...", "$type": "00"}
        if isinstance(binary, str):
            results.append((label, base64.b64decode(binary)))
            return

        # Name the payload after the document it came from, when we can.
        doc_label = label
        raw_id = node.get("_id")
        if isinstance(raw_id, dict):
            raw_id = raw_id.get("$oid")
        if raw_id:
            doc_label = str(raw_id)

        for key, value in node.items():
            if key in ("_id", "_class"):
                continue
            child = doc_label if key == "fileData" else f"{doc_label}.{key}"
            _walk_for_binaries(value, results, child)

    elif isinstance(node, list):
        for index, value in enumerate(node):
            _walk_for_binaries(value, results, f"{label}[{index}]")

    elif isinstance(node, (bytes, bytearray)):
        results.append((label, bytes(node)))


def _try_json(text, label):
    """Parse mongoexport output: a JSON array, one object, or JSONL."""
    text = text.strip()
    if not text or text[0] not in "[{":
        return None

    docs = []
    try:
        docs = [json.loads(text)]
    except json.JSONDecodeError:
        # JSONL — mongoexport's default is one document per line.
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                docs.append(json.loads(line))
            except json.JSONDecodeError:
                return None
    if not docs:
        return None

    results = []
    for index, doc in enumerate(docs):
        _walk_for_binaries(doc, results, f"{label}-{index}" if len(docs) > 1 else label)
    return results or None


def _try_bson(data, label):
    """Parse mongodump output (.bson: concatenated BSON documents)."""
    if len(data) < 5 or data[0] == 0:
        return None
    # A BSON document opens with its own little-endian length.
    declared = int.from_bytes(data[:4], "little")
    if declared < 5 or declared > len(data):
        return None
    try:
        docs = bson.decode_all(data)
    except Exception:
        return None

    results = []
    for index, doc in enumerate(docs):
        _walk_for_binaries(doc, results, f"{label}-{index}" if len(docs) > 1 else label)
    return results or None


def _try_base64(data, label):
    """A file that is nothing but base64 text."""
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        return None
    stripped = "".join(text.split())
    if len(stripped) < 16 or not set(text) <= BASE64_CHARS:
        return None
    try:
        decoded = base64.b64decode(stripped, validate=True)
    except (binascii.Error, ValueError):
        return None
    # Guard against a plain-text file that happens to be base64-legal: only accept
    # the decode if it yields something that looks like real content.
    if not decoded or sniff_extension(decoded) == ".bin" and b"\x00" not in decoded[:64]:
        return None
    return [(label, decoded)]


def decode_binary_file(path):
    """Return [(label, bytes)] for whatever shape the input file is in."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data:
        raise ValueError(f"{path} is empty")

    label = safe_name(os.path.splitext(os.path.basename(path))[0])

    for attempt, kind in (
            (lambda: _try_bson(data, label), "BSON (mongodump)"),
            (lambda: _try_json(data.decode("utf-8", "strict"), label)
             if _is_probably_text(data) else None, "Extended JSON (mongoexport)"),
            (lambda: _try_base64(data, label), "base64 text"),
    ):
        try:
            found = attempt()
        except (UnicodeDecodeError, ValueError, binascii.Error):
            found = None
        if found:
            return kind, found

    # Nothing matched — it is the binary itself.
    return "raw binary", [(label, data)]


def _is_probably_text(data):
    return b"\x00" not in data[:4096]


def run_file_mode(args):
    """--input: decode a file's binary payload and write it out as plain text."""
    try:
        kind, payloads = decode_binary_file(args.input)
    except (OSError, ValueError) as exc:
        sys.exit(f"Could not read {args.input}: {exc}")

    print(f"Input:  {args.input}")
    print(f"Format: {kind}")
    print(f"Found:  {len(payloads)} binary payload(s)\n")

    for label, data in payloads:
        size_kb = len(data) / 1024.0

        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            # A real binary (an .xlsx model, say) has no plain-text form.
            print(f"  - {label}  {size_kb:8.1f} KB  NOT text ({sniff_extension(data)}) — "
                  "writing the raw bytes instead")
            text = None

        if args.out in (None, "-"):
            if text is None:
                sys.exit("Refusing to write binary to stdout — pass --out FILE.")
            sys.stdout.write(text)
            if not text.endswith("\n"):
                sys.stdout.write("\n")
            continue

        target = args.out
        if os.path.isdir(target) or len(payloads) > 1:
            os.makedirs(target, exist_ok=True)
            ext = ".py" if text is not None and sniff_extension(data) == ".py" else (
                ".txt" if text is not None else sniff_extension(data))
            target = os.path.join(target, f"{safe_name(label)}{ext}")

        if text is None:
            with open(target, "wb") as fh:
                fh.write(data)
        else:
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(text)
        print(f"  - {label}  {size_kb:8.1f} KB  ->  {target}")


def discover_tenants(client):
    """Every database that actually holds a ModelFiles collection."""
    tenants = []
    for db_name in client.list_database_names():
        if db_name in SYSTEM_DBS:
            continue
        if MODEL_FILES in client[db_name].list_collection_names():
            tenants.append(db_name)
    return sorted(tenants)


def build_name_index(db):
    """modelFileId -> (modelName, modelType), so files get meaningful names."""
    index = {}
    if MODELS not in db.list_collection_names():
        return index
    projection = {"modelFileId": 1, "modelName": 1, "modelType": 1, "isDeleted": 1}
    for model in db[MODELS].find({}, projection):
        file_id = model.get("modelFileId")
        if not file_id:
            continue
        index[str(file_id)] = (
            model.get("modelName"),
            model.get("modelType"),
            model.get("isDeleted", 0),
        )
    return index


def extract_tenant(db, out_root, tenant, list_only, overwrite):
    """Returns (written, skipped, empty) counts for one tenant database."""
    names = build_name_index(db)
    out_dir = os.path.join(out_root, safe_name(tenant))

    written = skipped = empty = 0
    total = db[MODEL_FILES].estimated_document_count()
    if total == 0:
        print(f"[{tenant}] no documents in {MODEL_FILES}")
        return 0, 0, 0

    print(f"[{tenant}] {total} document(s) in {MODEL_FILES}")

    for doc in db[MODEL_FILES].find({}):
        file_id = str(doc.get("_id"))
        content_type = doc.get("contentType") or ""
        data = raw_bytes(doc.get("fileData"))

        if not data:
            print(f"  ! {file_id}  EMPTY fileData  (contentType={content_type or 'none'})")
            empty += 1
            continue

        model_name, model_type, is_deleted = names.get(file_id, (None, None, None))
        ext = extension_for(content_type, model_type, data)

        if model_name:
            base = safe_name(model_name)
            label = f"{model_name} [{model_type or '?'}]"
            if is_deleted:
                base += ".deleted"
                label += " (soft-deleted)"
        else:
            base = f"orphan-{safe_name(file_id)}"
            label = "<no Model references this file>"

        filename = f"{base}{ext}"
        target = os.path.join(out_dir, filename)

        size_kb = len(data) / 1024.0
        print(f"  - {file_id}  {size_kb:9.1f} KB  {filename:<45} {label}")

        if list_only:
            continue

        os.makedirs(out_dir, exist_ok=True)

        # Two models can share a name; never silently clobber one with the other.
        if os.path.exists(target) and not overwrite:
            stem, suffix = os.path.splitext(filename)
            target = os.path.join(out_dir, f"{stem}.{file_id}{suffix}")
            if os.path.exists(target):
                print(f"    skipped, already extracted: {target}")
                skipped += 1
                continue

        with open(target, "wb") as fh:
            fh.write(data)
        written += 1

    return written, skipped, empty


def main():
    parser = argparse.ArgumentParser(
        description="Extract ModelFiles binaries from MongoDB to local disk.")
    parser.add_argument("--input", metavar="FILE",
                        help="decode a binary from a FILE instead of connecting to MongoDB "
                             "(.bson, mongoexport JSON, base64 text, or the raw bytes — "
                             "auto-detected). Writes the payload out as plain text.")
    parser.add_argument("--uri", default=os.environ.get("MONGODB_URI", DEFAULT_URI),
                        help="MongoDB connection URI (default: $MONGODB_URI, else localhost)")
    parser.add_argument("--username", default=os.environ.get("MONGODB_USERNAME"),
                        help="username, if not already embedded in the URI")
    parser.add_argument("--password", default=os.environ.get("MONGODB_PASSWORD"),
                        help="password, if not already embedded in the URI")
    parser.add_argument("--props", nargs="?", const=DEFAULT_PROPS, metavar="FILE",
                        help="read host/credentials from a Spring application properties "
                             f"file instead of --uri (default file: {DEFAULT_PROPS})")
    parser.add_argument("--tenant", action="append", dest="tenants", metavar="DB",
                        help="tenant database to extract (repeatable). Default: master")
    parser.add_argument("--all-tenants", action="store_true",
                        help="every database that has a ModelFiles collection")
    parser.add_argument("--out", default=None, metavar="DIR",
                        help="output directory (default: ./model-files; with --input, an "
                             "output file or directory, or '-' for stdout)")
    parser.add_argument("--list", action="store_true", dest="list_only",
                        help="show what would be extracted, write nothing")
    parser.add_argument("--overwrite", action="store_true",
                        help="overwrite existing files instead of suffixing with the file id")
    args = parser.parse_args()

    # --input is a self-contained mode: no connection, no tenants, no discovery.
    if args.input:
        conflicting = [flag for flag, used in (
            ("--all-tenants", args.all_tenants),
            ("--tenant", bool(args.tenants)),
            ("--props", bool(args.props)),
        ) if used]
        if conflicting:
            sys.exit(f"--input reads a local file; {', '.join(conflicting)} does not apply.")
        run_file_mode(args)
        return

    if args.out is None:
        args.out = "./model-files"

    if args.props:
        if not os.path.exists(args.props):
            sys.exit(f"Properties file not found: {args.props}")
        uri = uri_from_properties(args.props)
        print(f"Connection: from {args.props}")
    else:
        uri = args.uri
    if args.username and "@" not in uri.split("//", 1)[-1].split("/", 1)[0]:
        scheme, rest = uri.split("//", 1)
        creds = quote_plus(args.username)
        if args.password:
            creds += ":" + quote_plus(args.password)
        uri = f"{scheme}//{creds}@{rest}"

    try:
        client = MongoClient(uri, serverSelectionTimeoutMS=5000)
        client.admin.command("ping")
    except Exception as exc:
        sys.exit(f"Could not connect to MongoDB: {exc}")

    if args.all_tenants:
        try:
            tenants = discover_tenants(client)
        except OperationFailure as exc:
            sys.exit(f"Could not list databases: {exc}\n"
                     "The connection needs credentials — pass --props to read them from the "
                     "project's application properties, or supply --username/--password.")
        if not tenants:
            sys.exit("No database with a ModelFiles collection found.")
    else:
        tenants = args.tenants or ["master"]

    print(f"Tenants: {', '.join(tenants)}")
    if args.list_only:
        print("(--list: nothing will be written)\n")
    else:
        print(f"Output:  {os.path.abspath(args.out)}\n")

    totals = [0, 0, 0]
    for tenant in tenants:
        try:
            w, s, e = extract_tenant(client[tenant], args.out, tenant,
                                     args.list_only, args.overwrite)
        except OperationFailure as exc:
            print(f"[{tenant}] skipped — {exc}\n")
            continue
        totals[0] += w
        totals[1] += s
        totals[2] += e
        print()

    if args.list_only:
        print("Done (listing only).")
    else:
        msg = f"Done. {totals[0]} file(s) written"
        if totals[1]:
            msg += f", {totals[1]} already present"
        if totals[2]:
            msg += f", {totals[2]} with empty fileData"
        print(msg + ".")


if __name__ == "__main__":
    main()
