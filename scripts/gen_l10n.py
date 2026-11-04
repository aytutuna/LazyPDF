#!/usr/bin/env python3
"""Writes windows/LazyPDF.Core/Strings.tr.resx from l10n/shared.json and checks the catalog
against the code.

The catalog maps an English text to its translation: {"Cancel": {"tr": "İptal"}}. A plural is
keyed by its singular and carries the other form: {"{0} page": {"other": "{0} pages", "tr": "{0} sayfa"}}.
Loc.T, Loc.Plural and {loc:T ...} in windows/ are the only places a key may come from, so the
script fails on a text the code uses and the catalog lacks, on one the catalog has and nothing
uses, on a missing translation and on placeholders that differ.

  --check   validate, write nothing
  --sync    append the texts the code uses and the catalog lacks, with an empty translation
  --todo    print what still has no translation
"""
import html
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "l10n" / "shared.json"
RESX = ROOT / "windows" / "LazyPDF.Core" / "Strings.tr.resx"
SKIP_DIRS = {"bin", "obj", "LazyPDF.Core.Tests", "LazyPDF.App.Tests"}
LANGUAGES = ["tr"]
HEADER = "Written by scripts/gen_l10n.py from l10n/shared.json; do not edit."

PLACEHOLDER = re.compile(r"\{([0-9]+)\}")
LITERAL = r'"((?:[^"\\]|\\.)*)"'
CALL = re.compile(r"\bLoc\.T\(\s*" + LITERAL)
TERNARY = re.compile(r"\bLoc\.T\(\s*[^\"\s][^\"?;]*\?\s*" + LITERAL + r"\s*:\s*" + LITERAL)
PLURAL = re.compile(r"\bLoc\.Plural\([^,]+,\s*" + LITERAL + r"\s*,\s*" + LITERAL)
# "a" + "b" would be read as "a" alone, and never found at run time.
SPLIT = re.compile(r"\bLoc\.T\(\s*" + LITERAL + r"\s*\+")


def unescape(literal):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), literal)


def xaml_texts(text):
    """The text of every {loc:T ...}. The end is found by brace depth: a text may hold {0}."""
    for start in re.finditer(r"\{loc:T\s", text):
        depth, i = 1, start.end()
        while i < len(text) and depth:
            if text[i] == "\\":
                i += 1
            elif text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        raw = html.unescape(text[start.end():i - 1]).strip()
        if raw.startswith("{}"):
            raw = raw[2:]
        if len(raw) > 1 and raw[0] == raw[-1] == "'":
            raw = raw[1:-1]
        yield re.sub(r"\\(.)", r"\1", raw)


def no_duplicates(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            sys.exit(f"duplicate key: {key!r}")
        out[key] = value
    return out


def keys_in_code():
    """({key: (first file, plural other or None)}, [(text, file)] for split literals)."""
    found, split = {}, []
    for path in sorted((ROOT / "windows").rglob("*")):
        rel = path.relative_to(ROOT)
        if path.suffix not in (".cs", ".xaml") or SKIP_DIRS & set(rel.parts):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        where = rel.as_posix()
        if path.suffix == ".xaml":
            for key in xaml_texts(text):
                found.setdefault(key, (where, None))
            continue
        split += [(unescape(m.group(1)), where) for m in SPLIT.finditer(text)]
        for m in TERNARY.finditer(text):
            for literal in m.groups():
                found.setdefault(unescape(literal), (where, None))
        for m in CALL.finditer(text):
            found.setdefault(unescape(m.group(1)), (where, None))
        for m in PLURAL.finditer(text):
            found[unescape(m.group(1))] = (where, unescape(m.group(2)))
    return found, split


def placeholders(text):
    return sorted(PLACEHOLDER.findall(text))


def resx_text(pairs):
    out = ['<?xml version="1.0" encoding="utf-8"?>', "<root>", f"  <!-- {HEADER} -->"]
    for name, value in (
        ("resmimetype", "text/microsoft-resx"),
        ("version", "2.0"),
        ("reader", "System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"),
        ("writer", "System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"),
    ):
        out += [f'  <resheader name="{name}">', f"    <value>{value}</value>", "  </resheader>"]
    for k, v in pairs:
        out += [f'  <data name="{escape(k, {chr(34): "&quot;"})}" xml:space="preserve">', f"    <value>{escape(v)}</value>", "  </data>"]
    out.append("</root>")
    return "\n".join(out) + "\n"


def main():
    args = set(sys.argv[1:])
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"), object_pairs_hook=no_duplicates)
    used, split = keys_in_code()

    if "--sync" in args:
        for key, (_, other) in used.items():
            if key not in catalog:
                catalog[key] = {"other": other} if other else {}
        CATALOG.write_bytes((json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        print(f"{len(catalog)} entries")
        return

    errors = [f"split over two literals, never found: {text!r} ({where})" for text, where in split]
    for key, (where, other) in used.items():
        if key not in catalog:
            errors.append(f"not in the catalog: {key!r} ({where})")
        elif other is not None and catalog[key].get("other") != other:
            errors.append(f"plural form differs: {key!r} ({where})")
    names = {}
    for key, entry in catalog.items():
        if key not in used:
            errors.append(f"not used by the code: {key!r}")
        for code in LANGUAGES:
            text = entry.get(code, "")
            if not text:
                errors.append(f"no {code}: {key!r}")
                continue
            forms = [key] + ([entry["other"]] if "other" in entry else [])
            if placeholders(text) not in [placeholders(f) for f in forms]:
                errors.append(f"placeholders differ in {code}: {key!r}")
        name = key.lower()
        if name in names:
            errors.append(f"resx name collides ignoring case: {key!r} and {names[name]!r}")
        names[name] = key
    if "--todo" in args:
        print("\n".join(e for e in errors if e.startswith("no ")))
        return
    if errors:
        sys.exit("\n".join(errors))

    if "--check" in args:
        return
    pairs = sorted((key + ("|plural" if "other" in entry else ""), entry["tr"]) for key, entry in catalog.items())
    RESX.write_bytes(resx_text(pairs).encode("utf-8"))
    print(f"{len(pairs)} texts in {RESX.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
