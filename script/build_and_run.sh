#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build|--debug|--logs|--telemetry) ;; *) echo 'Usage: script/build_and_run.sh [--build|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;; esac
if [[ "$MODE" != --build ]]; then
  # Target only this checkout's bundle. Lite handles SIGTERM through its normal
  # save/close flow; a website's canceled close must never be forced through.
  while read -r process_id process_command; do
    if [[ "$process_command" == "$ROOT_DIR/dist/Lite.app/Contents/MacOS/Lite" || "$process_command" == "$ROOT_DIR/dist/Lite.app/Contents/MacOS/Lite "* ]]; then
      kill -TERM "$process_id"
      for attempt in {1..30}; do
        kill -0 "$process_id" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$process_id" 2>/dev/null; then
        echo 'Lite is still closing. Resolve any unsaved-page prompt, then run again.' >&2
        exit 1
      fi
    fi
  done < <(ps -axo pid=,command=)
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
python3 script/fetch_cef.py
cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH="$(uname -m)"
cmake --build .build -j 8
ctest --test-dir .build --output-on-failure
python3 script/package.py
case "$MODE" in
  --build) ;;
  --debug) lldb -- "$ROOT_DIR/dist/Lite.app/Contents/MacOS/Lite" ;;
  --logs|--telemetry) open -n "$ROOT_DIR/dist/Lite.app"; /usr/bin/log stream --info --style compact --predicate 'process == "Lite"' ;;
  --verify) open -n "$ROOT_DIR/dist/Lite.app"; sleep 3; pgrep -x Lite >/dev/null; echo 'Lite process is running.' ;;
  run) open -n "$ROOT_DIR/dist/Lite.app" ;;
esac
