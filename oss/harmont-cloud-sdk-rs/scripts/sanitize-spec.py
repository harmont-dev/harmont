#!/usr/bin/env python3
"""
Strip empty media-type objects from OpenAPI spec responses.

OpenApiSpex emits invalid empty `"application/json": {}` content objects for
some 204 responses; progenitor 0.14 panics on these. This script removes any
media-type entry whose value is an empty object `{}` (no schema, no encoding,
nothing), then drops the `content` key entirely if it becomes empty.

Remove this script and the sanitize step from `make codegen-sdk-rs` once the
upstream OpenApiSpex fix lands and the Elixir spec is updated.

Usage:
    python3 sanitize-spec.py <openapi.json>   (edits in place)
"""

import json
import sys


def sanitize(spec: dict) -> int:
    """Remove empty media-type objects from all response content maps.

    Returns the count of removed entries.
    """
    removed = 0
    for methods in spec.get("paths", {}).values():
        for op in methods.values():
            if not isinstance(op, dict):
                continue
            for resp in op.get("responses", {}).values():
                if not isinstance(resp, dict):
                    continue
                content = resp.get("content")
                if not isinstance(content, dict):
                    continue
                empty_keys = [k for k, v in content.items() if v == {}]
                for k in empty_keys:
                    del content[k]
                    removed += 1
                if not content:
                    del resp["content"]
    return removed


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <openapi.json>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        spec = json.load(fh)

    removed = sanitize(spec)

    with open(path, "w", encoding="utf-8") as fh:
        json.dump(spec, fh, indent=2, ensure_ascii=True)
        fh.write("\n")

    print(f"sanitize-spec: removed {removed} empty media-type object(s) from {path}")


if __name__ == "__main__":
    main()
