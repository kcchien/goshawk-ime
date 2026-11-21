#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="debug"
MAX_DEPTH="4"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIG="release"
      shift
      ;;
    --max-depth)
      MAX_DEPTH="${2:?Missing value for --max-depth}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

exec swift run -c "$CONFIG" GoshawkVerifier --max-depth "$MAX_DEPTH"
