#!/usr/bin/env python3
"""Check repository-local Markdown links and anchors without network access."""
from pathlib import Path
import re
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]


def heading_anchors(path):
    identifiers = []
    for title in re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), re.M):
        title = re.sub(r"[`*_]", "", title).lower()
        slug = re.sub(r"[^\w\- ]", "", title).replace(" ", "-")
        suffix = sum(value == slug or re.fullmatch(re.escape(slug) + r"-\d+", value) is not None
                     for value in identifiers)
        identifiers.append(slug + (f"-{suffix}" if suffix else ""))
    return set(identifiers)


def main():
    files = [*sorted(ROOT.glob("*.md")), *sorted((ROOT / "docs").rglob("*.md")),
             *sorted((ROOT / "Acknowledgements").glob("*.md"))]
    errors = []
    count = 0
    for source in files:
        for target in re.findall(r"(?<!!)\[[^\]\n]+\]\(([^\s)]+)\)", source.read_text()):
            if re.match(r"^[a-zA-Z]+:", target):
                continue
            path, _, anchor = urllib.parse.unquote(target.strip("<>")).partition("#")
            # This preserved upstream notice has links relative to its original checkout.
            base = ROOT / ".build/checkouts/swift-readability" if source.name == "SwiftReadability-THIRD-PARTY-NOTICES.md" else source.parent
            resolved = (base / path).resolve() if path else source
            count += 1
            if not resolved.exists():
                errors.append(f"{source.relative_to(ROOT)}: missing {target}")
            elif anchor and resolved.suffix == ".md" and anchor not in heading_anchors(resolved):
                errors.append(f"{source.relative_to(ROOT)}: missing anchor {target}")
    print(f"Checked {len(files)} Markdown files and {count} local links/anchors.")
    for error in errors:
        print(error)
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
