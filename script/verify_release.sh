#!/usr/bin/env bash
# One local/CI entry point. Browser fixtures always use disposable profiles.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
case "${1:-}" in ''|--measure) ;; *) echo 'Usage: script/verify_release.sh [--measure]' >&2; exit 2 ;; esac
mkdir -p test-results/release
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
python3 script/fetch_cef.py
python3 script/fetch_sparkle.py
cmake -S . -B .build -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH="$(uname -m)"
cmake --build .build -j 8
ctest --test-dir .build --output-on-failure | tee test-results/release/ctest.log
python3 script/test_updates.py 2>&1 | tee test-results/release/updates.log
python3 script/test_endurance.py 2>&1 | tee test-results/release/endurance-runner.log
python3 script/package.py 2>&1 | tee test-results/release/package.log
python3 script/test_browser.py 2>&1 | tee test-results/release/browser.log
python3 script/test_native.py 2>&1 | tee test-results/release/native.log
codesign --verify --deep --strict dist/Lite.app
codesign -dv --verbose=4 dist/Lite.app 2>test-results/release/signature.log
if [[ "${1:-}" == --measure ]]; then
    python3 script/measure_native.py --duration 20 --output test-results/release/native-measurement.json
fi
git diff --check
