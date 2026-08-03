"""Self-contained test for the docs toolchain guard.

Run: python3 scripts/test_check_docs_toolchains.py
No test framework — plain asserts, exits non-zero on failure.
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

import check_docs_toolchains as guard


def test_retired_set_derivation() -> None:
    allowed = {"rust", "go", "python", "py", "js", "ts", "ruby", "cmake", "zig", "elixir"}
    retired = guard.retired_toolchains(allowed)
    assert "haskell" in retired
    assert "npm" in retired
    assert "gradle" in retired
    # Live toolchains must never be flagged as retired.
    assert "rust" not in retired
    assert "js" not in retired
    assert "elixir" not in retired


def test_scan_flags_retired_factory() -> None:
    retired = {"haskell", "npm", "ocaml"}
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        (root / "bad.md").write_text("Use `hm.haskell(ghc='9.6.7')` to build.\n")
        (root / "also_bad.py").write_text("project = hm.npm(path='.')\n")
        (root / "fine.md").write_text("Use `hm.js.project(path='.')` instead.\n")
        hits = guard.scan_living_docs([root], retired)
    files = {h.path.name for h in hits}
    assert "bad.md" in files
    assert "also_bad.py" in files
    assert "fine.md" not in files


def test_scan_flags_cidsl() -> None:
    retired: set[str] = set()
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        (root / "stale.md").write_text("The DSL lives in cidsl/py.\n")
        hits = guard.scan_living_docs([root], retired)
    assert any(h.path.name == "stale.md" for h in hits)


def test_clean_tree_has_no_hits() -> None:
    retired = {"haskell", "npm"}
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        (root / "ok.md").write_text("hm.js.project(path='.') and hm.rust(path='.')\n")
        hits = guard.scan_living_docs([root], retired)
    assert hits == []


def test_scannable_set_filters_out_unlisted_files() -> None:
    # A retired-factory reference in a file NOT in the scannable set (e.g. the
    # gitignored examples/ fetch) must be skipped; a sibling that IS scannable
    # is still flagged.
    retired = {"npm"}
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d)
        ignored = root / "ignored.md"
        scanned = root / "scanned.md"
        ignored.write_text("project = hm.npm(path='.')\n")
        scanned.write_text("project = hm.npm(path='.')\n")
        hits = guard.scan_living_docs(
            [root], retired, scannable={scanned.resolve()}
        )
    names = {h.path.name for h in hits}
    assert "scanned.md" in names
    assert "ignored.md" not in names


def main() -> int:
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok - {name}")
    print("all guard tests passed")
    return 0


if __name__ == "__main__":
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    sys.exit(main())
