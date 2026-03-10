#!/usr/bin/env bash
set -euo pipefail

addon_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
luajit_bin="${LUAJIT_BIN:-luajit}"

if ! command -v "$luajit_bin" >/dev/null 2>&1; then
  echo "Error: '$luajit_bin' not found. Install it with: brew install luajit" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=()
  while IFS= read -r file; do
    files+=("$file")
  done < <(find "$addon_dir" -maxdepth 1 -type f -name "*.lua" | sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No Lua files found to check."
  exit 0
fi

tmpfile="$(mktemp "${TMPDIR:-/tmp}/iirl-bytecode.XXXXXX")"
cleanup() {
  rm -f "$tmpfile"
}
trap cleanup EXIT

failed=0
for file in "${files[@]}"; do
  if "$luajit_bin" -b "$file" "$tmpfile" >/dev/null; then
    echo "OK   $file"
  else
    echo "FAIL $file" >&2
    failed=1
  fi
done

if [[ $failed -ne 0 ]]; then
  exit 1
fi

echo "All Lua syntax checks passed."
