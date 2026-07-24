"""Export foobar2000 v2 metadb.sqlite to JSON for the Dart seed migration.

Usage: python export_metadb.py <metadb.sqlite> <out.json>
"""
import json
import ntpath
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

FILETIME_EPOCH = datetime(1601, 1, 1, tzinfo=timezone.utc)
PREFIX = "0+file://"


def main(db_path: str, out_path: str) -> None:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    records = []
    for name, created, size in con.execute(
        "SELECT name, created, size FROM metadb WHERE created IS NOT NULL"
    ):
        if not name.startswith(PREFIX):
            continue
        path = name[len(PREFIX):]
        created_dt = FILETIME_EPOCH + timedelta(microseconds=created / 10)
        records.append({
            "basename": ntpath.basename(path).lower(),
            "size": size,
            "created": created_dt.isoformat(),
        })
    con.close()
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"records": records}, f)
    print(f"exported {len(records)} records to {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
