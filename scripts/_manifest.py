#!/usr/bin/env python3
"""Read/append integration.toml. Emits TSV so bash scripts stay simple.

Dependency-free: parses the small, controlled subset of TOML this skill writes
(top-level tables, arrays-of-tables, quoted-string and bool scalars, # comments)
so it runs on any Python 3.x — including the system python3 that lacks tomllib.

Usage:
  _manifest.py <repo_root> constituents
      -> name<TAB>path<TAB>remote<TAB>default_branch  (one line per constituent)
  _manifest.py <repo_root> get <key|section.key>
      -> value from [integration]/[compositions], or an explicit section.key
  _manifest.py <repo_root> add <name> <path> <remote> <default_branch>
      -> append a [[constituent]] block (idempotent by name)
"""
import sys
from pathlib import Path


def _scalar(raw: str):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    if raw == "true":
        return True
    if raw == "false":
        return False
    return raw


def parse(text: str) -> dict:
    """Return {tables: {name: {k:v}}, arrays: {name: [ {k:v}, ... ]}}."""
    tables: dict = {}
    arrays: dict = {}
    ctx = None  # current dict to assign key/values into
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[["):
            name = s[2:s.index("]]")].strip()
            ctx = {}
            arrays.setdefault(name, []).append(ctx)
            continue
        if s.startswith("["):
            name = s[1:s.index("]")].strip()
            ctx = tables.setdefault(name, {})
            continue
        if "=" in s and ctx is not None:
            k, _, v = s.partition("=")
            # strip a trailing inline comment that is not inside quotes
            vv = v.strip()
            if vv[:1] not in "\"'" and "#" in vv:
                vv = vv[: vv.index("#")].strip()
            ctx[k.strip()] = _scalar(vv)
    return {"tables": tables, "arrays": arrays}


def load(root: Path) -> dict:
    p = root / "integration.toml"
    if not p.exists():
        sys.exit(f"error: no integration.toml at {root}")
    return parse(p.read_text(encoding="utf-8"))


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    root = Path(sys.argv[1]).resolve()
    cmd = sys.argv[2]

    if cmd == "constituents":
        data = load(root)
        for c in data["arrays"].get("constituent", []):
            print("\t".join([
                str(c.get("name", "")),
                str(c.get("path", "")),
                str(c.get("remote", "")),
                str(c.get("default_branch", "main")),
            ]))

    elif cmd == "get":
        data = load(root)
        key = sys.argv[3]
        if "." in key:
            sect, k = key.split(".", 1)
            node = data["tables"].get(sect, {})
        else:
            k = key
            node = {**data["tables"].get("integration", {}),
                    **data["tables"].get("compositions", {})}
        val = node.get(k, "")
        if isinstance(val, bool):
            val = "true" if val else "false"
        print(val)

    elif cmd == "add":
        if len(sys.argv) < 7:
            sys.exit("usage: add <name> <path> <remote> <default_branch>")
        name, path, remote, branch = sys.argv[3:7]
        data = load(root)
        if any(c.get("name") == name for c in data["arrays"].get("constituent", [])):
            sys.exit(f"error: constituent '{name}' already in manifest")
        block = (
            f"\n[[constituent]]\n"
            f'name = "{name}"\n'
            f'path = "{path}"\n'
            f'remote = "{remote}"\n'
            f'default_branch = "{branch}"\n'
        )
        with (root / "integration.toml").open("a", encoding="utf-8") as fh:
            fh.write(block)
        print(f"registered {name}")

    else:
        sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
