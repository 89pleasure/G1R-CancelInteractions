#!/usr/bin/env python3

import argparse
import re
import sqlite3
from pathlib import Path


def detect_fields(line: str) -> dict:
    """
    Best-effort Parser für UE4SS Object Dumps.
    Da Dump-Formate je nach Spiel/UE4SS-Version variieren können,
    speichern wir immer raw_line und extrahieren nur, was sicher wirkt.
    """

    line = line.strip()

    result = {
        "raw_line": line,
        "object_type": None,
        "class_name": None,
        "object_name": None,
        "full_path": None,
        "package_path": None,
    }

    # Häufige Unreal-Pfade sehen ungefähr so aus:
    # /Game/UI/WBP_Inventory.WBP_Inventory_C
    # /Script/Engine.PlayerController
    path_match = re.search(r"(/(?:Game|Script|Engine|Plugin|Plugins|Temp|Memory|Verse)[^\s'\"]+)", line)
    if path_match:
        full_path = path_match.group(1).rstrip(",)")
        result["full_path"] = full_path

        if "." in full_path:
            result["package_path"] = full_path.rsplit(".", 1)[0]
            result["object_name"] = full_path.rsplit(".", 1)[1]
        else:
            result["package_path"] = full_path

    # Pattern wie:
    # Class /Script/Engine.PlayerController
    # WidgetBlueprintGeneratedClass /Game/UI/WBP_Inventory.WBP_Inventory_C
    leading_type_match = re.match(r"^([A-Za-z_][A-Za-z0-9_]+)\s+", line)
    if leading_type_match:
        result["object_type"] = leading_type_match.group(1)

    # Pattern wie:
    # Class: Something
    # Object: Something
    class_match = re.search(r"(?:Class|class|ClassName)\s*[:=]\s*([A-Za-z0-9_./]+)", line)
    if class_match:
        result["class_name"] = class_match.group(1)

    # Falls kein class_name gefunden wurde, versuche aus typischen Unreal-Klassen zu schließen.
    if result["class_name"] is None:
        common_class_match = re.search(
            r"\b("
            r"BlueprintGeneratedClass|WidgetBlueprintGeneratedClass|Blueprint|"
            r"Class|Function|Struct|Enum|Property|Object|Package|Texture2D|"
            r"Material|MaterialInstanceConstant|DataTable|CurveTable|World|Level"
            r")\b",
            line,
        )
        if common_class_match:
            result["class_name"] = common_class_match.group(1)

    # Falls object_name noch fehlt, letzten Pfadteil oder letzten Token nehmen.
    if result["object_name"] is None and result["full_path"]:
        last_part = result["full_path"].split("/")[-1]
        if "." in last_part:
            result["object_name"] = last_part.rsplit(".", 1)[-1]
        else:
            result["object_name"] = last_part

    return result


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS objects (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          raw_line TEXT NOT NULL,

          object_type TEXT,
          class_name TEXT,
          object_name TEXT,
          full_path TEXT,
          package_path TEXT,

          source_file TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_objects_class_name
          ON objects(class_name);

        CREATE INDEX IF NOT EXISTS idx_objects_object_name
          ON objects(object_name);

        CREATE INDEX IF NOT EXISTS idx_objects_full_path
          ON objects(full_path);

        CREATE INDEX IF NOT EXISTS idx_objects_package_path
          ON objects(package_path);

        CREATE VIRTUAL TABLE IF NOT EXISTS objects_fts
        USING fts5(raw_line, full_path, object_name, class_name);
        """
    )


def import_dump(input_file: Path, db_file: Path, reset: bool = False) -> None:
    conn = sqlite3.connect(db_file)

    if reset:
        conn.executescript(
            """
            DROP TABLE IF EXISTS objects;
            DROP TABLE IF EXISTS objects_fts;
            """
        )

    create_schema(conn)

    rows = []

    with input_file.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()

            if not line:
                continue

            fields = detect_fields(line)

            rows.append(
                (
                    fields["raw_line"],
                    fields["object_type"],
                    fields["class_name"],
                    fields["object_name"],
                    fields["full_path"],
                    fields["package_path"],
                    str(input_file),
                )
            )

    with conn:
        conn.executemany(
            """
            INSERT INTO objects (
              raw_line,
              object_type,
              class_name,
              object_name,
              full_path,
              package_path,
              source_file
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )

        conn.execute("DELETE FROM objects_fts")

        conn.execute(
            """
            INSERT INTO objects_fts(rowid, raw_line, full_path, object_name, class_name)
            SELECT id, raw_line, full_path, object_name, class_name
            FROM objects
            """
        )

    conn.close()

    print(f"Imported {len(rows)} lines into {db_file}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_file", help="Path to UE4SS_ObjectDump.txt")
    parser.add_argument("--db", default="ue4ss_dump.db", help="SQLite output DB")
    parser.add_argument("--reset", action="store_true", help="Drop existing tables before import")

    args = parser.parse_args()

    import_dump(
        input_file=Path(args.input_file),
        db_file=Path(args.db),
        reset=args.reset,
    )


if __name__ == "__main__":
    main()