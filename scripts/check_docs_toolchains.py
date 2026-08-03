#!/usr/bin/env python3
"""Fail if any hand-written ("living") doc references a retired DSL toolchain.

The set of live toolchains is derived from the DSL's own
`harmont/__init__.py` __all__, so when a toolchain is removed from the DSL
it automatically becomes "retired" here and any lingering `hm.<name>(` call
in the docs starts failing — no denylist to hand-maintain.

Two checks, both fail-closed:
  A) No living doc calls a retired `hm.<name>(` factory, and none mentions
     the dead `cidsl` DSL package name.
  B) The gitignored generated reference dirs contain no git-tracked files
     (that is how a stale generated page, e.g. haskell.mdx, would sneak in).

Usage:
  python3 scripts/check_docs_toolchains.py            # run the guard
  python3 scripts/check_docs_toolchains.py --self-test  # run the unit test
"""
from __future__ import annotations

import ast
import dataclasses
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

ALL_EXPORTS_FILE = (
    REPO
    / "harmont-cli/crates/hm-dsl-engine/harmont-py/harmont/__init__.py"
)

# Every toolchain factory name that has ever existed in the DSL. Anything in
# here but NOT in the live __all__ is "retired" and must not appear in docs.
# Add a name here only when a brand-new toolchain factory ships.
KNOWN_TOOLCHAIN_UNIVERSE = {
    "rust", "go", "python", "py", "js", "ts", "ruby", "cmake", "zig",
    "elixir", "haskell", "ocaml", "elm", "perl", "dotnet", "composer",
    "gradle", "npm", "node", "bun", "deno",
}

# Non-factory stale strings that should never appear in living docs.
STALE_STRINGS = ("cidsl",)

# Hand-written doc roots we own and must keep current. Submodule and dated
# archives are deliberately excluded.
LIVING_DOC_ROOTS = [
    REPO / "README.md",
    REPO / "examples",
    REPO / "docs-site/content/docs/getting-started.mdx",
    REPO / "docs-site/content/docs/cli",
    REPO / "docs-site/content/docs/examples",
    REPO / "docs-site/content/docs/pipeline-sdk",
    REPO / "docs-site/content/docs/sdk",
    REPO / "docs-site/content/docs/api/_intros",
    REPO / "docs-site/content/docs/agents.mdx",
    REPO / "docs-site/content/docs/architecture.mdx",
]

# Generated, gitignored reference output — never hand-written, never tracked.
GENERATED_REFERENCE_DIRS = [
    "docs-site/content/docs/api/reference",
    "docs-site/content/docs/sdk/reference",
    "docs-site/content/docs/pipeline-sdk/reference",
]

DOC_SUFFIXES = {".md", ".mdx", ".py", ".ts", ".tsx", ".astro", ".txt"}


@dataclasses.dataclass(frozen=True)
class Hit:
    path: pathlib.Path
    line: int
    text: str
    reason: str


def live_toolchains() -> set[str]:
    """Parse __all__ from the DSL and intersect with the known universe."""
    if not ALL_EXPORTS_FILE.exists():
        raise SystemExit(
            "check-docs-toolchains: DSL exports file not found at "
            f"{ALL_EXPORTS_FILE} — is the harmont-cli submodule initialized? "
            "Run `git submodule update --init`."
        )
    src = ALL_EXPORTS_FILE.read_text(encoding="utf-8")
    tree = ast.parse(src)
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
            if "__all__" in targets and isinstance(node.value, (ast.List, ast.Tuple)):
                for elt in node.value.elts:
                    if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                        names.add(elt.value)
    if not names:
        raise SystemExit(
            f"check-docs-toolchains: could not parse __all__ from {ALL_EXPORTS_FILE}"
        )
    return KNOWN_TOOLCHAIN_UNIVERSE & names


def retired_toolchains(allowed: set[str]) -> set[str]:
    return KNOWN_TOOLCHAIN_UNIVERSE - allowed


def scannable_files() -> set[pathlib.Path]:
    """Files git considers part of the repo: tracked + new, minus ignored.

    This is the set check-A polices. Gitignored content — the build-time
    `examples/` fetch from the submodule, the generated reference dirs, the
    *-api.json artifacts — is excluded, because it is downstream of sources
    that are themselves current (the submodule, the DSL). New hand-written
    docs (untracked but not ignored) are still scanned.
    """
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=REPO, capture_output=True, text=True, check=False,
    )
    # Fail closed: if git is unavailable/errors, we cannot tell which files are
    # in scope — better to abort loudly than to silently scan nothing and pass.
    if out.returncode != 0:
        raise SystemExit(
            "check-docs-toolchains: `git ls-files` failed "
            f"(exit {out.returncode}); cannot determine scannable files.\n"
            f"{out.stderr.strip()}"
        )
    return {(REPO / ln).resolve() for ln in out.stdout.splitlines() if ln.strip()}


def _iter_doc_files(root: pathlib.Path, scannable: set[pathlib.Path] | None):
    if root.is_file():
        if scannable is None or root.resolve() in scannable:
            yield root
        return
    if not root.exists():
        return
    for path in root.rglob("*"):
        if not (path.is_file() and path.suffix in DOC_SUFFIXES):
            continue
        if scannable is not None and path.resolve() not in scannable:
            continue
        yield path


def scan_living_docs(
    roots: list[pathlib.Path],
    retired: set[str],
    scannable: set[pathlib.Path] | None = None,
) -> list[Hit]:
    """Scan ``roots`` for retired-toolchain references.

    When ``scannable`` is given, only files in that set are read (production
    passes the git-derived set from :func:`scannable_files`). When ``None``,
    every matching file under each root is read (used by the unit tests, which
    operate on throwaway temp dirs outside the repo).
    """
    hits: list[Hit] = []
    factory_res = {
        name: re.compile(r"hm\." + re.escape(name) + r"\b")
        for name in retired
    }
    stale_res = {s: re.compile(re.escape(s)) for s in STALE_STRINGS}
    for root in roots:
        for path in _iter_doc_files(root, scannable):
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(lines, start=1):
                for name, rx in factory_res.items():
                    if rx.search(line):
                        hits.append(
                            Hit(path, i, line.strip(),
                                f"retired toolchain factory `hm.{name}`")
                        )
                for s, rx in stale_res.items():
                    if rx.search(line):
                        hits.append(
                            Hit(path, i, line.strip(),
                                f"dead reference `{s}`")
                        )
    return hits


def tracked_generated_files() -> list[str]:
    """Generated reference dirs must stay untracked (gitignored)."""
    out = subprocess.run(
        ["git", "ls-files", "--", *GENERATED_REFERENCE_DIRS],
        cwd=REPO, capture_output=True, text=True, check=False,
    )
    return [ln for ln in out.stdout.splitlines() if ln.strip()]


def main() -> int:
    allowed = live_toolchains()
    retired = retired_toolchains(allowed)
    hits = scan_living_docs(LIVING_DOC_ROOTS, retired, scannable=scannable_files())
    tracked = tracked_generated_files()

    if not hits and not tracked:
        print(
            "check-docs-toolchains: OK "
            f"(live toolchains: {', '.join(sorted(allowed))})"
        )
        return 0

    print("check-docs-toolchains: FAIL\n", file=sys.stderr)
    for h in hits:
        rel = h.path.relative_to(REPO)
        print(f"  {rel}:{h.line}: {h.reason}", file=sys.stderr)
        print(f"      {h.text}", file=sys.stderr)
    if hits:
        print(
            "\n  -> These docs name a toolchain the DSL no longer ships. "
            f"Live toolchains: {', '.join(sorted(allowed))}. "
            "Fix the doc to use a current factory (e.g. `hm.js.project(...)`), "
            "or, if the toolchain was genuinely re-added, update the DSL.",
            file=sys.stderr,
        )
    for f in tracked:
        print(f"  {f}: generated reference file must not be git-tracked",
              file=sys.stderr)
    if tracked:
        print(
            "\n  -> Generated reference docs are gitignored and rebuilt by "
            "`make docs-generate`. Untrack them: "
            "`git rm --cached <file>` and let the build regenerate.",
            file=sys.stderr,
        )
    return 1


def _self_test() -> int:
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import test_check_docs_toolchains as t
    return t.main()


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        raise SystemExit(_self_test())
    raise SystemExit(main())
