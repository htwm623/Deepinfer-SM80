#!/usr/bin/env bash
# Prepare the offline vLLM base-tree archive for docker/Dockerfile.sm80.intranet.
#
# Run this ON AN INTERNET-CONNECTED HOST (needs GitHub access). It fetches the
# exact vLLM PR #56201 base commit as a shallow clone and packs it (git dir
# included, so the original commit SHA and the clean working tree survive the
# round-trip) into:
#
#   third_party/vllm-pr56201-base.tar.gz
#
# That archive is then COPY-ed into the intranet Docker build, which unpacks it
# to /workspace/vllm — scripts/apply_patches.sh's base-commit check passes
# unchanged. Commit the archive to git (or ship it alongside the repo) and run
# the intranet build.
#
# Usage:
#   scripts/prepare_vllm_bundle.sh [--out third_party/vllm-pr56201-base.tar.gz]
set -euo pipefail

BASE_COMMIT="79a7108d9aea27ddab99ce1779290d300b17fc23"
REMOTE="https://github.com/vllm-project/vllm.git"
DIR_NAME="vllm-pr56201-base"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/third_party/vllm-pr56201-base.tar.gz"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -e "$OUT" ]; then
  echo "error: $OUT already exists; remove it first (or pass --out)" >&2
  exit 64
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> fetching vLLM commit $BASE_COMMIT (depth-1, self-contained)"
git init -q "$TMP_DIR/$DIR_NAME"
git -C "$TMP_DIR/$DIR_NAME" remote add origin "$REMOTE"
# The commit only lives on the (closed) PR #56201 ref, but GitHub allows
# fetching an exact SHA directly; --depth 1 transfers just that one commit
# with all its blobs, so the archive needs no network afterwards.
# Transient TLS errors (common on WSL2) are retried.
for attempt in 1 2 3; do
  if git -C "$TMP_DIR/$DIR_NAME" fetch -q --depth 1 --no-tags origin "$BASE_COMMIT"; then
    break
  fi
  [ "$attempt" -eq 3 ] && exit 1
  echo "    fetch failed (attempt $attempt), retrying..."
  sleep 5
done
git -C "$TMP_DIR/$DIR_NAME" checkout -q "$BASE_COMMIT"

echo "==> verifying clean checkout at $BASE_COMMIT"
SHA="$(git -C "$TMP_DIR/$DIR_NAME" rev-parse HEAD)"
if [ "$SHA" != "$BASE_COMMIT" ]; then
  echo "error: checked out $SHA, expected $BASE_COMMIT" >&2
  exit 1
fi
if [ -n "$(git -C "$TMP_DIR/$DIR_NAME" status --porcelain)" ]; then
  echo "error: working tree is not clean" >&2
  exit 1
fi
# The depth-1 fetch is already self-contained; repack keeps the archive small.
git -C "$TMP_DIR/$DIR_NAME" repack -adq

mkdir -p "$(dirname "$OUT")"
echo "==> packing $OUT"
tar -czf "$OUT" -C "$TMP_DIR" "$DIR_NAME"

echo
echo "done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "next (intranet host):"
echo "  docker build -f docker/Dockerfile.sm80.intranet \\"
echo "      --build-arg PIP_INDEX_URL=https://your-mirror.example/simple \\"
echo "      -t deepinfer-sm80:cu130 ."
