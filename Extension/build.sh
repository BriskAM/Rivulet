#!/bin/sh
# Builds unpacked extensions into dist/chrome and dist/firefox.
# Usage: ./build.sh [--zip]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

zip_out=0
for arg in "$@"; do
  case "$arg" in
    --zip|-z) zip_out=1 ;;
    -h|--help)
      echo "Usage: ./build.sh [--zip]"
      echo "  Writes dist/chrome and dist/firefox; with --zip also dist/rivulet-chrome.zip and dist/rivulet-firefox.zip."
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

rm -rf dist
for target in chrome firefox; do
  [ -f "manifest.$target.json" ] || { echo "Missing manifest.$target.json" >&2; exit 1; }
  mkdir -p "dist/$target"
  cp -R src/. "dist/$target/"
  cp "manifest.$target.json" "dist/$target/manifest.json"
  find "dist/$target" -name .DS_Store -exec rm -f {} +
  echo "Built dist/$target"
done

if [ "$zip_out" -eq 1 ]; then
  command -v zip >/dev/null 2>&1 || { echo "zip not found" >&2; exit 1; }
  for target in chrome firefox; do
    (cd "dist/$target" && zip -q -r -X "../rivulet-$target.zip" .)
    echo "Wrote dist/rivulet-$target.zip"
  done
fi
