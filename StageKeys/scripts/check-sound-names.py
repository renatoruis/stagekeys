#!/usr/bin/env python3
"""Validates a sound folder against the bucket naming contract.

Usage: scripts/check-sound-names.py "<folder>"

Each file must be `Categoria - Nome.sf2` or `Categoria - Subcategoria - Nome.sf2`.
"""
import hashlib
import os
import sys

KNOWN = ["Nord", "Piano", "Electric Piano", "Organ", "Pad", "Strings", "Synth",
         "Bell", "Vox", "Accordion", "FX", "Collection"]
FORBIDDEN = set('/\\:?#%&+')


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(__doc__.strip())
        return 2
    root = sys.argv[1]
    errors, seen, categories = [], {}, {}
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if name.startswith(".") or not os.path.isfile(path):
            continue
        if not name.lower().endswith(".sf2"):
            print(f"ignored (not .sf2): {name}")
            continue
        stem = name[:-4]
        parts = stem.split(" - ")
        if len(parts) not in (2, 3):
            errors.append(f"{name}: expected 2 or 3 parts separated by ' - ', got {len(parts)}")
        elif any(p.strip() != p or not p for p in parts):
            errors.append(f"{name}: empty part or extra spaces")
        bad = FORBIDDEN & set(stem)
        if bad:
            errors.append(f"{name}: forbidden characters {''.join(sorted(bad))}")
        if len(parts) in (2, 3):
            subs = categories.setdefault(parts[0], set())
            if len(parts) == 3:
                subs.add(parts[1])
        digest = md5(path)
        if digest in seen:
            errors.append(f"{name}: duplicate of {seen[digest]}")
        else:
            seen[digest] = name

    for category in sorted(categories):
        tag = "" if category in KNOWN else "  (new category)"
        subs = ", ".join(sorted(categories[category]))
        print(f"{category}{tag}" + (f": {subs}" if subs else ""))
    for e in errors:
        print(f"ERROR {e}")
    print(f"{len(seen)} sounds, {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
