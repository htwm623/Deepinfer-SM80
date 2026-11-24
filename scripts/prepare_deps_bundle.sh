#!/usr/bin/env bash
# Prepare the offline dependency-source archive for docker/Dockerfile.sm80.intranet.
#
# Run this ON AN INTERNET-CONNECTED HOST (needs GitHub access). vLLM's CMake
# FetchContent populates 9 external repositories from GitHub during
# `pip install -e .`, unconditionally (even when the Ampere-only arch list
# skips their kernels), so an intranet build cannot reach them. This script
# downloads the exact pinned versions as source tarballs, lays them out under
# the directory names the Dockerfile's *_SRC_DIR variables expect, and packs:
#
#   third_party/vllm-deps-src.tar.gz
#
# Pinned versions, kept in sync with the vLLM base tree (commit
# 79a7108d9a, vllm/cmake/external_projects/*.cmake):
#   nvidia/cutlass         v4.7.1            (CMakeLists.txt CUTLASS_REVISION)
#   triton-lang/triton     v3.5.1            (triton_kernels.cmake)
#   deepseek-ai/DeepGEMM   8b1392b978...     (deepgemm.cmake)
#   vllm-project/MSA       087c161814...     (fmha_sm100.cmake)
#   vllm-project/FlashMLA  6bc49418c5...     (flashmla.cmake)
#   vllm-project/FlashKDA  3b225bf26b...     (flashkda.cmake)
#   IST-DASLab/qutlass     e74319e340...     (qutlass.cmake)
#   vllm-project/tml-fa4   b206834606...     (tml_fa4.cmake)
#   vllm-project/flash-attention 06bdd47c... (vllm_flash_attn.cmake)
#
# The source tarballs carry no git history, which the CMake builds do not
# need. flashkda's cutlass submodule is satisfied by symlinking the pinned
# cutlass checkout into flashkda/cutlass (only include/examples/tools are
# referenced; FlashKDA kernels are not compiled on Ampere).
#
# Usage:
#   scripts/prepare_deps_bundle.sh [--out third_party/vllm-deps-src.tar.gz]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/third_party/vllm-deps-src.tar.gz"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -e "$OUT" ]; then
  echo "error: $OUT already exists; remove it first (or pass --out)" >&2
  exit 64
fi

# name|repo|ref  (name = directory the Dockerfile's *_SRC_DIR points to)
DEPS=(
  "cutlass|nvidia/cutlass|v4.7.1"
  "deepgemm|deepseek-ai/DeepGEMM|8b1392b978f5a03c828dd1711090d7fb50958b8a"
  "fmha_sm100|vllm-project/MSA|087c161814d4d9c735b46c21212a09e5f8eb92fa"
  "flashmla|vllm-project/FlashMLA|6bc49418c5ead572ff0339191ddf3b155749e183"
  "flashkda|vllm-project/FlashKDA|3b225bf26bb8e218928a1fe14751cb48cf31d11b"
  "qutlass|IST-DASLab/qutlass|e74319e3405ce6d71965732880f5dc1f52371f64"
  "tml_fa4|vllm-project/tml-fa4|b206834606ed5b5f21f8eed6b0683f528ea9cf7d"
  "flash_attn|vllm-project/flash-attention|06bdd47c0d0383daf6a2ff0c418faff9c6da16e5"
  "triton|triton-lang/triton|v3.5.1"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/vllm-deps-src"
ROOT="$TMP_DIR/vllm-deps-src"

for dep in "${DEPS[@]}"; do
  IFS='|' read -r name repo ref <<< "$dep"
  echo "==> fetching $repo @ $ref"
  for attempt in 1 2 3; do
    if curl -fsSL --retry 3 -o "$TMP_DIR/$name.zip" "https://codeload.github.com/$repo/zip/$ref"; then
      break
    fi
    [ "$attempt" -eq 3 ] && exit 1
    echo "    download failed (attempt $attempt), retrying..."
    sleep 5
  done
  # The zip extracts to <repo>-<ref>; rename to the canonical name.
  python3 -c "import zipfile; zipfile.ZipFile('$TMP_DIR/$name.zip').extractall('$ROOT')"
  extracted="$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d -name '*-[0-9a-f]*' | head -1)"
  [ -n "$extracted" ] || extracted="$(find "$ROOT" -maxdepth 1 -mindepth 1 -type d | grep -iv "^$ROOT$" | head -1)"
  mv "$extracted" "$ROOT/$name"
done

echo "==> wiring flashkda's cutlass submodule to the pinned checkout"
mkdir -p "$ROOT/flashkda/cutlass"
ln -s ../../cutlass/include  "$ROOT/flashkda/cutlass/include"
ln -s ../../cutlass/examples "$ROOT/flashkda/cutlass/examples"
ln -s ../../cutlass/tools    "$ROOT/flashkda/cutlass/tools"

mkdir -p "$(dirname "$OUT")"
echo "==> packing $OUT"
# --dereference: bake the flashkda/cutlass links in as real files so the
# archive has no symlink assumptions about where it is unpacked.
tar -czf "$OUT" --dereference -C "$ROOT" .

echo
echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "next (intranet host):"
echo "  docker build -f docker/Dockerfile.sm80.intranet \\"
echo "      --build-arg PIP_INDEX_URL=https://your-mirror.example/simple \\"
echo "      -t deepinfer-sm80:cu130 ."
