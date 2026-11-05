#!/bin/bash
# The main window's layout matrix (Tests/TachoTests/LayoutMatrixTests.swift), whole, in both languages: swift test runs a smaller one in
# English only, since only a launch argument sets a language. With a folder as $1, every cell of the matrix is drawn there, and a contact
# sheet of each page. About five minutes a language.
# Usage: scripts/layout-matrix.sh [folder]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests
tests=$(swift build --show-bin-path)/TachoTests.xctest
sheet=${1:-}
if [ -n "$sheet" ]; then sheet=$(mkdir -p "$sheet" && cd "$sheet" && pwd); fi

status=0
for language in "en en_AU" "zh-Hans zh_Hans_AU"; do
    set -- $language
    echo "== $1 ($2)"
    TACHO_LAYOUT_MATRIX=full TACHO_LAYOUT_SHEET="$sheet" xcrun xctest -XCTest TachoTests.LayoutMatrixTests -AppleLanguages "($1)" -AppleLocale "$2" "$tests" || status=1
done
exit $status
