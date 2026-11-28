#!/bin/bash
# Builds the HTML test and coverage report for a finished package run:
#
#   swift test --enable-code-coverage --xunit-output build/report/tests.xml \
#       --package-path TwinPanesKit
#   scripts/test-report.sh build/report build/report/site build/report/summary.md
#
# The first argument is the folder holding the JUnit XML files (Swift 6 writes
# tests.xml for XCTest and tests-swift-testing.xml for Swift Testing). The second
# receives the site, ready for GitHub Pages: index.html and coverage/ from
# Tools/CoverageReport, tests.html from scripts/test-report.xsl. The third receives the
# job summary's Markdown, kept out of the site. Coverage covers TwinPanesKit/Sources.
set -euo pipefail

usage="usage: test-report.sh <junit xml folder> <site folder> <summary file>"
xml_dir=${1:?$usage}
out=${2:?$usage}
summary=${3:?$usage}
root=$(cd "$(dirname "$0")/.." && pwd)
package="$root/TwinPanesKit"
title="Twin Panes tests${GITHUB_SHA:+ at ${GITHUB_SHA:0:7}}"

rm -rf "$out"
mkdir -p "$out"

# Test results: one <runs> document from every JUnit file, then one HTML page.
combined=$(mktemp)
trap 'rm -f "$combined"' EXIT
{
    echo '<runs>'
    for file in "$xml_dir"/*.xml; do sed '/^<?xml/d' "$file"; done
    echo '</runs>'
} > "$combined"
xsltproc --stringparam title "$title" "$root/scripts/test-report.xsl" "$combined" > "$out/tests.html"

tests=$(grep -c '<testcase ' "$combined" || true)
failed=$(grep -cE '<(failure|error)[ >/]' "$combined" || true)
skipped=$(grep -c '<skipped' "$combined" || true)

# Coverage: every test bundle is an object file for llvm-cov. The export and the
# sources must come from this same checkout; the tool fails if a source is shorter than
# its coverage reaches.
bin=$(swift build --show-bin-path --package-path "$package")
profile="$(dirname "$(swift test --show-codecov-path --package-path "$package")")/default.profdata"
objects=()
for bundle in "$bin"/*Tests.xctest; do
    name=$(basename "$bundle" .xctest)
    objects+=(-object "$bundle/Contents/MacOS/$name")
done
export_file=$(mktemp)
trap 'rm -f "$combined" "$export_file"' EXIT
xcrun llvm-cov export "${objects[@]}" -instr-profile="$profile" \
    -ignore-filename-regex='(/Tests/|/\.build/)' -skip-functions > "$export_file"

# macOS's bash 3.2 treats an empty array as unset under `set -u`, hence the
# ${commit[@]+...} form.
commit=()
if [ -n "${GITHUB_SHA:-}" ]; then
    commit=(--commit "${GITHUB_SHA:0:7}")
fi
swift run --package-path "$root/Tools/CoverageReport" coverage-report \
    --export "$export_file" --sources "$package/Sources" --output "$out" \
    --summary "$summary" ${commit[@]+"${commit[@]}"} \
    --tests "$tests" --failed "$failed" --skipped "$skipped"
echo "Report written to $out"
