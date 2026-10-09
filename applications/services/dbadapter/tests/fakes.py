"""Minimal behavioural fakes of each SDK surface used by the drivers (unit tests only)."""

from __future__ import annotations

import json
import re
from collections import namedtuple
from datetime import UTC, datetime
from types import SimpleNamespace


def now():
    return datetime.now(UTC)


# ---------------------------------------------------------------- mssql-python (sync DB-API)
class FakeMssql:
    def __init__(self):
        self.rows: dict[str, list] = {}
        self.statements: list[str] = []
        self.connections = 0

    def connect(self, conn_str, autocommit=True, timeout=0):
        self.connections += 1
        self.conn_str = conn_str
        return _MssqlConn(self)


class _MssqlConn:
    def __init__(self, db):
        self.db = db

    def cursor(self):
        return _MssqlCursor(self.db)

    def close(self):
        pass


class _MssqlCursor:
    def __init__(self, db):
        self.db, self._result, self.rowcount = db, None, 0

    def execute(self, sql, params=()):
        s = " ".join(sql.split())
        self.db.statements.append(s)
        rows = self.db.rows
        if s.startswith("MERGE"):
            rid, payload = params
            existing = rows.get(rid)
            rows[rid] = [rid, payload, existing[2] if existing else now(), now()]
            self.rowcount = 1
        elif s.startswith("SELECT TOP"):
            self._result = sorted(rows.values(), key=lambda r: r[2], reverse=True)[: params[0]]
        elif s.startswith("SELECT id"):
            r = rows.get(params[0])
            self._result = [r] if r else []
        elif s.startswith("UPDATE"):
            payload, rid = params
            self.rowcount = 0
            if rid in rows:
                rows[rid][1], rows[rid][3] = payload, now()
                self.rowcount = 1
        elif s.startswith("DELETE"):
            self.rowcount = 1 if rows.pop(params[0], None) else 0
        else:
            self._result = [(1,)]

    def fetchone(self):
        return self._result[0] if self._result else None

    def fetchall(self):
        return list(self._result or [])


# ---------------------------------------------------------------- PyMySQL
class FakeMySql:
    def __init__(self):
        self.rows: dict[str, list] = {}
        self.passwords: list[str] = []

    def connect(self, **kwargs):
        self.passwords.append(kwargs["password"])
        self.kwargs = kwargs
        return SimpleNamespace(cursor=lambda: _MyCursor(self), close=lambda: None)


class _MyCursor:
    def __init__(self, db):
        self.db, self._r, self.rowcount = db, None, 0

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=None):
        s = " ".join(sql.split())
        rows = self.db.rows
        if s.startswith("INSERT"):
            rid, payload = params
            ex = rows.get(rid)
            rows[rid] = [rid, payload, ex[2] if ex else now(), now()]
        elif s.startswith("SELECT id") and "WHERE" in s:
            r = rows.get(params[0])
            self._r = [r] if r else []
        elif s.startswith("SELECT id"):
            self._r = sorted(rows.values(), key=lambda r: r[2], reverse=True)[: params[0]]
        elif s.startswith("UPDATE"):
            payload, rid = params
            if rid in rows:
                rows[rid][1], rows[rid][3] = payload, now()
        elif s.startswith("DELETE"):
            self.rowcount = 1 if rows.pop(params[0], None) else 0
        else:
            self._r = [(1,)]

    def fetchone(self):
        return self._r[0] if self._r else None

    def fetchall(self):
        return list(self._r or [])


class FakeToken:
    def __init__(self):
        self.n = 0

    def get(self):
        self.n += 1
        return f"entra-token-{self.n}"


# ---------------------------------------------------------------- azure-cosmos (async container)
class FakeCosmosContainer:
    def __init__(self):
        self.items: dict[str, dict] = {}

    async def read(self):
        return {"id": "records"}

    async def read_item(self, item, partition_key):
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        assert item == partition_key
        if item not in self.items:
            raise CosmosResourceNotFoundError(message="nf")
        return dict(self.items[item])

    async def upsert_item(self, body):
        self.items[body["id"]] = dict(body)
        return dict(body)

    async def replace_item(self, item, body):
        self.items[item] = dict(body)
        return dict(body)

    async def delete_item(self, item, partition_key):
        from azure.cosmos.exceptions import CosmosResourceNotFoundError

        if item not in self.items:
            raise CosmosResourceNotFoundError(message="nf")
        del self.items[item]

    def query_items(self, query, parameters):
        n = parameters[0]["value"]
        items = sorted(self.items.values(), key=lambda i: i["created_at"], reverse=True)[:n]

        async def gen():
            for i in items:
                yield i

        return gen()


# ---------------------------------------------------------------- cassandra-driver session
Row = namedtuple("Row", "id payload created_at updated_at")


class FakeCassandraSession:
    def __init__(self):
        self.rows: dict[str, Row] = {}

    def execute(self, cql, params=()):
        s = " ".join(cql.split())
        if s.startswith("INSERT"):
            rid, payload, created, updated = params
            self.rows[rid] = Row(rid, payload, created.replace(tzinfo=None), updated.replace(tzinfo=None))
            return []
        if s.startswith("SELECT id") and "WHERE" in s:
            r = self.rows.get(params[0])
            return [r] if r else []
        if s.startswith("SELECT id"):
            return list(self.rows.values())[: params[0]]
        if s.startswith("UPDATE"):
            payload, updated, rid = params
            self.rows[rid] = self.rows[rid]._replace(payload=payload, updated_at=updated.replace(tzinfo=None))
            return []
        if s.startswith("DELETE"):
            self.rows.pop(params[0], None)
            return []
        return [SimpleNamespace(release_version="5.0")]


# ---------------------------------------------------------------- gremlinpython client
class FakeGremlinClient:
    def __init__(self):
        self.v: dict[str, dict] = {}
        self.queries = []

    def _vertex(self, rid):
        props = self.v[rid]
        return {"id": rid, "label": "record", "properties": {k: [{"value": val}] for k, val in props.items()}}

    def submit(self, query, bindings):
        self.queries.append((query, bindings))
        result = self._run(query, bindings)
        return SimpleNamespace(all=lambda: SimpleNamespace(result=lambda timeout=None: result))

    def _run(self, q, b):
        if q.startswith("g.addV"):
            self.v[b["rid"]] = {"pk": b["pk"], "payload": b["payload"], "created_at": b["ts"], "updated_at": b["ts"]}
            return [self._vertex(b["rid"])]
        if "sideEffect(drop())" in q:
            return [1 if self.v.pop(b["rid"], None) else 0]
        if ".property('payload'" in q:
            if b["rid"] not in self.v:
                return []
            self.v[b["rid"]].update(payload=b["payload"], updated_at=b["ts"])
            return [self._vertex(b["rid"])]
        if q.startswith("g.V(rid)"):
            return [self._vertex(b["rid"])] if b["rid"] in self.v else []
        if "order()" in q:
            ids = sorted(self.v, key=lambda k: self.v[k]["created_at"], reverse=True)[: b["n"]]
            return [self._vertex(i) for i in ids]
        return [len(self.v)]

    def close(self):
        pass


# ---------------------------------------------------------------- azure-data-tables (async TableClient)
class _Entity(dict):
    metadata = {"etag": "W/1"}


class FakeTableClient:
    def __init__(self):
        self.e: dict[tuple, dict] = {}

    async def create_table(self):
        from azure.core.exceptions import ResourceExistsError

        raise ResourceExistsError("exists")

    def query_entities(self, flt, results_per_page=None, select=None):
        items = [_Entity(v) for v in self.e.values()]

        async def gen():
            for i in items:
                yield i

        return gen()

    async def get_entity(self, pk, rk):
        from azure.core.exceptions import ResourceNotFoundError

        if (pk, rk) not in self.e:
            raise ResourceNotFoundError("nf")
        return _Entity(self.e[(pk, rk)])

    async def upsert_entity(self, entity, mode=None):
        self.e[(entity["PartitionKey"], entity["RowKey"])] = dict(entity)

    async def update_entity(self, entity, mode=None, etag=None, match_condition=None):
        assert etag == "W/1"
        self.e[(entity["PartitionKey"], entity["RowKey"])] = dict(entity)

    async def delete_entity(self, pk, rk):
        self.e.pop((pk, rk), None)

    async def close(self):
        pass


# ---------------------------------------------------------------- redis.asyncio
class FakeRedis:
    def __init__(self):
        self.d, self.t = {}, {}

    async def ping(self):
        return True

    async def set(self, k, v, ex=None):
        self.d[k], self.t[k] = v, ex

    async def get(self, k):
        return self.d.get(k)

    async def ttl(self, k):
        return self.t.get(k, -2)

    async def delete(self, k):
        return 1 if self.d.pop(k, None) is not None else 0

    async def scan_iter(self, match=None, count=None):
        rx = re.compile(match.replace("*", ".*"))
        for k in list(self.d):
            if rx.fullmatch(k):
                yield k

    async def aclose(self):
        pass


# ---------------------------------------------------------------- confidential ledger
class FakeLedger:
    def __init__(self):
        self.entries: list[dict] = []

    def _poller(self, value):
        return SimpleNamespace(result=lambda: value)

    def begin_create_ledger_entry(self, entry, collection_id=None):
        tx = f"2.{len(self.entries) + 10}"
        self.entries.append({"transactionId": tx, "contents": entry["contents"], "collectionId": collection_id})
        return self._poller({"transactionId": tx, "state": "Committed"})

    def begin_get_ledger_entry(self, tx, collection_id=None):
        from azure.core.exceptions import ResourceNotFoundError

        for e in self.entries:
            if e["transactionId"] == tx:
                return self._poller({"entry": e, "state": "Ready"})
        raise ResourceNotFoundError("nf")

    def list_ledger_entries(self, collection_id=None):
        return iter(self.entries)

    def get_current_ledger_entry(self, collection_id=None):
        return {}

    def close(self):
        pass


# ---------------------------------------------------------------- blob / adls
class _Download:
    def __init__(self, data):
        self.data = data

    async def readall(self):
        return self.data


class FakeBlobContainer:
    def __init__(self):
        self.blobs: dict[str, bytes] = {}

    async def get_container_properties(self):
        return {}

    async def download_blob(self, name):
        from azure.core.exceptions import ResourceNotFoundError

        if name not in self.blobs:
            raise ResourceNotFoundError("nf")
        return _Download(self.blobs[name])

    async def upload_blob(self, name, data, overwrite=False, content_settings=None):
        self.blobs[name] = data.encode() if isinstance(data, str) else data

    async def delete_blob(self, name):
        from azure.core.exceptions import ResourceNotFoundError

        if name not in self.blobs:
            raise ResourceNotFoundError("nf")
        del self.blobs[name]

    def list_blobs(self, name_starts_with=""):
        names = [n for n in self.blobs if n.startswith(name_starts_with)]

        async def gen():
            for n in names:
                yield SimpleNamespace(name=n)

        return gen()


class FakeFileSystem:
    def __init__(self):
        self.files: dict[str, bytes] = {}

    async def get_file_system_properties(self):
        return {}

    def get_file_client(self, path):
        fs = self

        class FC:
            async def download_file(self):
                from azure.core.exceptions import ResourceNotFoundError

                if path not in fs.files:
                    raise ResourceNotFoundError("nf")
                return _Download(fs.files[path])

            async def upload_data(self, data, overwrite=False):
                fs.files[path] = data.encode() if isinstance(data, str) else data

            async def delete_file(self):
                from azure.core.exceptions import ResourceNotFoundError

                if path not in fs.files:
                    raise ResourceNotFoundError("nf")
                del fs.files[path]

        return FC()

    def get_paths(self, path, recursive=False):
        names = [n for n in self.files if n.startswith(path + "/")]

        async def gen():
            for n in names:
                yield SimpleNamespace(name=n, is_directory=False)

        return gen()


# ---------------------------------------------------------------- AI Search
class FakeSearchClient:
    def __init__(self):
        self.docs: dict[str, dict] = {}

    async def get_document_count(self):
        return len(self.docs)

    async def get_document(self, key):
        from azure.core.exceptions import ResourceNotFoundError

        if key not in self.docs:
            raise ResourceNotFoundError("nf")
        return dict(self.docs[key])

    async def merge_or_upload_documents(self, docs):
        for d in docs:
            self.docs[d["id"]] = {**self.docs.get(d["id"], {}), **d}

    async def merge_documents(self, docs):
        await self.merge_or_upload_documents(docs)

    async def delete_documents(self, docs):
        for d in docs:
            self.docs.pop(d["id"], None)

    async def search(self, search_text, top, order_by):
        items = sorted(self.docs.values(), key=lambda d: d["created_at"], reverse=True)[:top]

        async def gen():
            for i in items:
                yield i

        return gen()

    async def close(self):
        pass


# ---------------------------------------------------------------- Kusto
class FakeKusto:
    """Implements the subset of KQL the adx driver emits, over an append-only row list."""

    def __init__(self):
        self.rows: list[dict] = []
        self.mgmt: list[str] = []

    def execute_mgmt(self, db, cmd):
        self.mgmt.append(cmd)
        if cmd.startswith(".ingest inline"):
            import csv
            import io

            line = cmd.split("<|\n", 1)[1]
            rid, payload, created, updated, deleted = next(csv.reader(io.StringIO(line)))
            self.rows.append({"id": rid, "payload": json.loads(payload), "created_at": created, "updated_at": updated, "deleted": deleted == "true"})
        return SimpleNamespace(primary_results=[[]])

    def execute_query(self, db, kql):
        m = re.search(r"where id == '([^']*)'", kql)
        rows = [r for r in self.rows if not m or r["id"] == m.group(1)]
        latest: dict[str, dict] = {}
        for r in rows:
            if r["id"] not in latest or r["updated_at"] >= latest[r["id"]]["updated_at"]:
                latest[r["id"]] = r
        out = [r for r in latest.values() if not r["deleted"]]
        if "count" in kql and "summarize" not in kql:
            out = [{"Count": len(self.rows)}]
        return SimpleNamespace(primary_results=[[SimpleNamespace(to_dict=lambda r=r: dict(r)) for r in out]])

    def close(self):
        pass
