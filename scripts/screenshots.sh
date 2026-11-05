#!/bin/bash
# Renders the README's screenshots from the app's real views on made-up data: docs/images/*.png and docs/images/zh/*.png.
# Usage: scripts/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests
tests=$(swift build --show-bin-path)/TachoTests.xctest

# One process for each language, as in the app: only a launch argument sets one, and swift test cannot pass it.
TACHO_SCREENSHOTS=docs/images xcrun xctest -XCTest TachoTests.ReadmeScreenshots/testRender -AppleLanguages '(en)' -AppleLocale en_US "$tests"
TACHO_SCREENSHOTS=docs/images/zh xcrun xctest -XCTest TachoTests.ReadmeScreenshots/testRender -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN "$tests"
