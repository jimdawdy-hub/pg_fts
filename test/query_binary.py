#!/usr/bin/env python3
"""Check valid and malformed binary queries in an explicitly named disposable container.
Usage: python3 test/query_binary.py CONTAINER
   or: pg_virtualenv python3 test/query_binary.py --local
Never run crash-risk extension tests in a server hosting other work.
"""
import json
import pathlib
import struct
import subprocess
import sys

container = sys.argv[1]
base = (["psql", "-X", "-A", "-t", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        if container == "--local" else
        ["docker", "exec", "-i", container, "psql", "-X", "-A", "-t",
         "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"])


def sql(text):
    result = subprocess.run(base + ["-c", text], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def val(flags=0, distance=0, op=0, term="alpha"):
    raw = term.encode()
    return struct.pack("!BBHII", 1, op, flags, distance, len(raw)) + raw


def operator(op, distance=0, flags=0):
    return struct.pack("!BBHI", 2, op, flags, distance)


def binary(items):
    query = struct.pack("!HI", 2, len(items)) + b"".join(items)
    header = b"PGCOPY\n\xff\r\n\x00" + struct.pack("!ii", 0, 0)
    return header + struct.pack("!hi", 1, len(query)) + query + struct.pack("!h", -1)


sql("CREATE EXTENSION IF NOT EXISTS pg_fts; CREATE TABLE IF NOT EXISTS recv_review(q ftsquery);")
valid = [
    ("plain", [val()]),
    ("prefix", [val(1)]),
    ("fuzzy_one", [val(2, 1)]),
    ("fuzzy_intmax", [val(2, 2147483647)]),
    ("regex", [val(4)]),
    ("weighted_d", [val(8, 1)]),
    ("weighted_all", [val(8, 15)]),
    ("weighted_prefix", [val(9, 8)]),
    ("not", [val(), operator(1)]),
]
for name, op, distance in [
    ("and", 2, 0), ("or", 3, 0), ("legacy_and", 2, 1),
    ("legacy_or", 3, 1), ("legacy_phrase_zero", 4, 0),
    ("phrase_one", 4, 1), ("phrase_uintmax", 4, 4294967295),
    ("within_one", 5, 1), ("within_uintmax", 5, 4294967295),
    ("exact_zero", 6, 0), ("exact_one", 6, 1), ("exact_uintmax", 6, 4294967295),
]:
    valid.append((name, [val(), val(term="beta"), operator(op, distance)]))

invalid = [
    ("unknown_flags", [val(16)]),
    ("prefix_fuzzy", [val(3, 1)]),
    ("prefix_regex", [val(5)]),
    ("fuzzy_regex", [val(6, 1)]),
    ("all_patterns", [val(7, 1)]),
    ("fuzzy_weight", [val(10, 1)]),
    ("regex_weight", [val(12, 1)]),
    ("value_opcode", [val(op=1)]),
    ("weight_zero", [val(8, 0)]),
    ("weight_large", [val(8, 16)]),
    ("weight_uintmax", [val(8, 4294967295)]),
    ("prefix_weight_zero", [val(9, 0)]),
    ("fuzzy_zero", [val(2, 0)]),
    ("fuzzy_int_overflow", [val(2, 2147483648)]),
    ("fuzzy_uintmax", [val(2, 4294967295)]),
    ("plain_distance", [val(0, 1)]),
    ("prefix_distance", [val(1, 1)]),
    ("regex_distance", [val(4, 1)]),
    ("not_distance", [val(), operator(1, 1)]),
    ("operator_stack", [operator(6, 1)]),
]
for name, op, distance, flags in [
    ("operator_flags", 6, 1, 1), ("and_distance", 2, 2, 0),
    ("or_distance", 3, 4294967295, 0), ("within_zero", 5, 0, 0),
    ("unknown_operator", 7, 0, 0),
]:
    invalid.append((name, [val(), val(term="beta"), operator(op, distance, flags)]))

report = {"container": container, "valid": [], "invalid": []}
for expect_valid, cases in [(True, valid), (False, invalid)]:
    for name, items in cases:
        sql("TRUNCATE recv_review")
        result = subprocess.run(base + ["-c", "COPY recv_review FROM STDIN BINARY"],
                                input=binary(items), capture_output=True)
        accepted = result.returncode == 0
        if accepted != expect_valid:
            raise AssertionError((name, accepted, result.stderr.decode()))
        entry = {"name": name, "accepted": accepted}
        if accepted:
            entry["text"] = sql("SELECT q::text FROM recv_review")
            if name in ("legacy_and", "legacy_or"):
                expected = binary([val(), val(term="beta"),
                                   operator(2 if name == "legacy_and" else 3)])
                raw = subprocess.run(base + ["-c", "COPY recv_review TO STDOUT BINARY"],
                                     capture_output=True, check=True).stdout
                assert raw == expected, name + " was not normalized"
            if name == "legacy_phrase_zero":
                assert sql("SELECT to_ftsdoc('alpha beta') @@@ q FROM recv_review") == "f"
        else:
            entry["error"] = result.stderr.decode().splitlines()[0]
            assert "invalid ftsquery" in entry["error"], entry
        report["valid" if accepted else "invalid"].append(entry)

report["passed"] = len(valid) + len(invalid)
pathlib.Path("/tmp/pgfts-receiver-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"passed": report["passed"], "valid": len(valid), "invalid": len(invalid)}))
