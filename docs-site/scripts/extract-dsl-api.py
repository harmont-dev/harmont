#!/usr/bin/env python3
"""Extract the harmont Python DSL public API into normalized JSON via griffe.

    python docs-site/scripts/extract-dsl-api.py <harmont-py-dir> <out.json>

griffe statically loads the package (no import side effects) and parses
Google-style docstrings into structured sections. We walk that model and emit
our own small schema (see the plan's shared contract) so the TS generator never
sees griffe's expression trees.

Relies on the toolchain refactor: each toolchain singleton resolves through an
alias to an attribute annotated with a public `XxxEntry` class.
"""

from __future__ import annotations

import json
import sys

import griffe

# Every harmont.__all__ name maps to (group, page). A missing entry is a hard
# error — that guarantees no public symbol silently falls out of the docs.
PAGE_MAP: dict[str, tuple[str, str]] = {
    "scratch": ("chains", "chains"),
    "sh": ("chains", "chains"),
    "wait": ("chains", "chains"),
    "timeout": ("chains", "chains"),
    "Step": ("chains", "chains"),
    "group": ("chains", "chains"),
    "target": ("chains", "chains"),
    "pipeline": ("pipeline", "pipeline"),
    "pipeline_to_json": ("pipeline", "pipeline"),
    "Pipeline": ("pipeline", "pipeline"),
    "dump_registry_json": ("pipeline", "pipeline"),
    "ttl": ("cache", "cache"),
    "on_change": ("cache", "cache"),
    "forever": ("cache", "cache"),
    "compose": ("cache", "cache"),
    "CacheCompose": ("cache", "cache"),
    "CacheForever": ("cache", "cache"),
    "CacheNone": ("cache", "cache"),
    "CacheOnChange": ("cache", "cache"),
    "CachePolicy": ("cache", "cache"),
    "CacheTTL": ("cache", "cache"),
    "push": ("triggers", "triggers"),
    "pull_request": ("triggers", "triggers"),
    "pr": ("triggers", "triggers"),
    "rust": ("toolchains", "toolchains/rust"),
    "RustProject": ("toolchains", "toolchains/rust"),
    "python": ("toolchains", "toolchains/python"),
    "py": ("toolchains", "toolchains/python"),
    "cmake": ("toolchains", "toolchains/cmake"),
    "CMakeProject": ("toolchains", "toolchains/cmake"),
    "CMakeToolchain": ("toolchains", "toolchains/cmake"),
    "elixir": ("toolchains", "toolchains/elixir"),
    "go": ("toolchains", "toolchains/go"),
    "zig": ("toolchains", "toolchains/zig"),
    "js": ("toolchains", "toolchains/js"),
    "ts": ("toolchains", "toolchains/js"),
    "JsProject": ("toolchains", "toolchains/js"),
    "apt_base": ("toolchains", "toolchains/base"),
    "BaseImage": ("toolchains", "toolchains/base"),
    "Target": ("toolchains", "toolchains/base"),
}

# Public toolchain name -> (private module, public entry class). The entry
# class's public methods are rendered as the toolchain's methods.
TOOLCHAINS: dict[str, tuple[str, str]] = {
    "rust": ("_rust", "RustEntry"),
    "python": ("_python", "PythonEntry"),
    "cmake": ("_cmake", "CMakeEntry"),
    "elixir": ("_elixir", "ElixirEntry"),
    "go": ("_go", "GoEntry"),
    "zig": ("_zig", "ZigEntry"),
    "js": ("_js", "_JsEntry"),
}

KIND_MAP = {
    "positional-only": "positional_only",
    "positional or keyword": "positional_or_keyword",
    "variadic positional": "var_positional",
    "keyword-only": "keyword_only",
    "variadic keyword": "var_keyword",
}


def _ann(expr: object) -> str | None:
    return None if expr is None else str(expr)


def _default(value: object) -> str | None:
    # griffe gives defaults as source strings, or Expr objects (e.g. tuple
    # literals), or None when the parameter/field is required.
    return None if value is None else str(value)


def _parse_doc(obj: griffe.Object) -> dict:
    out = {"summary": "", "description": "", "params": {}, "returns_doc": "", "examples": []}
    ds = getattr(obj, "docstring", None)
    if ds is None:
        return out
    texts: list[str] = []
    try:
        sections = ds.parsed
    except Exception:  # noqa: BLE001 — malformed docstring: fall back to raw value
        out["summary"] = (ds.value or "").strip().split("\n", 1)[0]
        return out
    for sec in sections:
        kind = sec.kind.value
        if kind == "text":
            texts.append(sec.value)
        elif kind == "parameters":
            for p in sec.value:
                out["params"][p.name] = p.description or ""
        elif kind == "returns":
            if sec.value:
                out["returns_doc"] = sec.value[0].description or ""
        elif kind == "examples":
            for item in sec.value:
                out["examples"].append(item[1] if isinstance(item, tuple) else str(item))
    if texts:
        joined = "\n\n".join(t.strip() for t in texts if t.strip())
        out["summary"] = joined.split("\n", 1)[0].strip()
        out["description"] = joined.strip()
    return out


def _signature(func: griffe.Function) -> dict:
    doc = _parse_doc(func)
    params = []
    for p in func.parameters:
        if p.name in ("self", "cls"):
            continue
        params.append(
            {
                "name": p.name,
                "kind": KIND_MAP.get(p.kind.value, p.kind.value),
                "annotation": _ann(p.annotation),
                "default": _default(p.default),
                "doc": doc["params"].get(p.name, ""),
            }
        )
    return {
        "params": params,
        "returns": {"annotation": _ann(func.returns), "doc": doc["returns_doc"]},
    }


def _method_record(func: griffe.Function) -> dict:
    doc = _parse_doc(func)
    return {
        "name": func.name,
        "summary": doc["summary"],
        "description": doc["description"],
        "examples": doc["examples"],
        "signature": _signature(func),
    }


def _public_methods(cls: griffe.Object) -> list[dict]:
    methods = []
    for name, member in cls.members.items():
        if name.startswith("_"):
            continue
        if getattr(member, "kind", None) and member.kind.value == "function":
            methods.append(_method_record(member))
    methods.sort(key=lambda m: m["name"])
    return methods


def _fields(cls: griffe.Object) -> list[dict]:
    fields = []
    for name, member in cls.members.items():
        if name.startswith("_"):
            continue
        if getattr(member, "kind", None) and member.kind.value == "attribute":
            fields.append(
                {
                    "name": name,
                    "annotation": _ann(getattr(member, "annotation", None)),
                    "default": _default(getattr(member, "value", None)),
                }
            )
    return fields


def _class_symbol(name: str, cls: griffe.Object, group: str, page: str) -> dict:
    doc = _parse_doc(cls)
    is_dc = "dataclass" in getattr(cls, "labels", set())
    return {
        "name": name,
        "kind": "dataclass" if is_dc else "class",
        "group": group,
        "page": page,
        "summary": doc["summary"],
        "description": doc["description"],
        "examples": doc["examples"],
        "signature": None,
        "fields": _fields(cls) if is_dc else [],
        "methods": _public_methods(cls),
    }


def build(pkg_dir: str) -> dict:
    mod = griffe.load("harmont", search_paths=[pkg_dir], docstring_parser="google")
    public = list(mod.exports or [])
    if not public:
        # exports may be None if __all__ wasn't statically resolvable; read it.
        all_attr = mod.members.get("__all__")
        public = list(all_attr.value) if all_attr is not None else []
    public = [str(n).strip("'\"") for n in public]

    missing = [n for n in public if n not in PAGE_MAP]
    if missing:
        raise SystemExit(
            "extract-dsl-api: harmont.__all__ symbols have no PAGE_MAP entry: "
            f"{sorted(missing)}\n  -> add each to PAGE_MAP in extract-dsl-api.py"
        )

    by_name: dict[str, dict] = {}

    for name in public:
        group, page = PAGE_MAP[name]
        if name in TOOLCHAINS:
            mod_name, cls_name = TOOLCHAINS[name]
            entry = mod[mod_name][cls_name]
            doc = _parse_doc(entry)
            by_name[name] = {
                "name": name,
                "kind": "singleton",
                "group": group,
                "page": page,
                "summary": doc["summary"],
                "description": doc["description"],
                "examples": doc["examples"],
                # callable toolchain (e.g. hm.python(...)) exposes __call__.
                "signature": _signature(entry["__call__"]) if "__call__" in entry.members else None,
                "fields": [],
                "methods": _public_methods(entry),
            }
            continue

        obj = mod[name].final_target if mod[name].is_alias else mod[name]
        kind = obj.kind.value
        if kind == "function":
            doc = _parse_doc(obj)
            by_name[name] = {
                "name": name,
                "kind": "function",
                "group": group,
                "page": page,
                "summary": doc["summary"],
                "description": doc["description"],
                "examples": doc["examples"],
                "signature": _signature(obj),
                "fields": [],
                "methods": [],
            }
        elif kind == "class":
            by_name[name] = _class_symbol(name, obj, group, page)
        # attributes/modules in __all__ (e.g. `py`) are documented via page prose.

    # Discover public result dataclasses defined in each toolchain module.
    for name, (mod_name, _entry_cls) in TOOLCHAINS.items():
        page = PAGE_MAP[name][1]
        submod = mod[mod_name]
        for cname, cobj in submod.members.items():
            if cname.startswith("_") or cname in by_name:
                continue
            if getattr(cobj, "kind", None) and cobj.kind.value == "class":
                by_name[cname] = _class_symbol(cname, cobj, "toolchains", page)

    symbols = sorted(by_name.values(), key=lambda s: (s["page"], s["name"]))
    return {"version": "1", "package": "harmont", "symbols": symbols}


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract-dsl-api.py <harmont-py-dir> <out.json>")
    payload = build(sys.argv[1])
    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    print(f"extract-dsl-api: wrote {len(payload['symbols'])} symbols to {sys.argv[2]}")


if __name__ == "__main__":
    main()
