#!/usr/bin/env bash
# Every rule named in spec/semantics.md (a line starting `[T-…]`, `[E-…]` or
# `[P-…]`) tags exactly one match arm in spec/lean/Nobi (`-- [X-…]`), and
# every tag names exactly one rule there.
set -euo pipefail

lean="$(cd "$(dirname "$0")/.." && pwd)"
doc="$lean/../semantics.md"

doc_names=$(grep -oE '^\[(T|E|P)-[^]]+\]' "$doc" | sort)
tag_names=$(grep -rhoE -- '-- \[(T|E|P)-[^]]+\]' "$lean/Nobi" | sed 's/^-- //' | sort)

status=0
for what in doc tag; do
  names="${what}_names"
  dups=$(printf '%s\n' "${!names}" | uniq -d)
  if [ -n "$dups" ]; then
    echo "rule-names: named more than once in the $what: $dups" >&2
    status=1
  fi
done

missing=$(comm -23 <(printf '%s\n' "$doc_names" | sort -u) <(printf '%s\n' "$tag_names" | sort -u))
untagged=$(comm -13 <(printf '%s\n' "$doc_names" | sort -u) <(printf '%s\n' "$tag_names" | sort -u))
if [ -n "$missing" ]; then
  echo "rule-names: in semantics.md but no Lean arm is tagged:" $missing >&2
  status=1
fi
if [ -n "$untagged" ]; then
  echo "rule-names: tagged in Lean but not in semantics.md:" $untagged >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "rule-names: ok, $(printf '%s\n' "$doc_names" | grep -c .) rules"
fi
exit "$status"
