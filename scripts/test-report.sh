#!/bin/bash
# Builds the HTML test and coverage report for a finished package run:
#
#   swift test --enable-code-coverage --xunit-output build/report/tests.xml \
#       --package-path TwinPanesKit
#   scripts/test-report.sh build/report build/report/site
#
# The first argument is the folder holding the JUnit XML files (Swift 6 writes
# tests.xml for XCTest and tests-swift-testing.xml for Swift Testing). The second
# receives index.html, tests.html and coverage/, ready for GitHub Pages, plus
# summary.md for the job summary. Coverage covers TwinPanesKit/Sources only.
set -euo pipefail

xml_dir=${1:?usage: test-report.sh <junit xml folder> <output folder>}
out=${2:?usage: test-report.sh <junit xml folder> <output folder>}
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

# Coverage: every test bundle is an object file for llvm-cov. The pages are laid out
# by absolute source path (llvm-cov makes even -path-equivalence targets absolute), so
# publish only reports built on CI, where that path is the runner's checkout.
bin=$(swift build --show-bin-path --package-path "$package")
profile="$(dirname "$(swift test --show-codecov-path --package-path "$package")")/default.profdata"
objects=()
for bundle in "$bin"/*Tests.xctest; do
    name=$(basename "$bundle" .xctest)
    objects+=(-object "$bundle/Contents/MacOS/$name")
done
coverage_args=(
    "${objects[@]}"
    -instr-profile="$profile"
    -ignore-filename-regex='(/Tests/|/\.build/)'
)
xcrun llvm-cov show "${coverage_args[@]}" -format=html -show-line-counts-or-regions \
    -project-title="Twin Panes" -output-dir="$out/coverage" > /dev/null
report=$(xcrun llvm-cov report "${coverage_args[@]}")

# Per-module line coverage from the text report: columns 8 and 9 are lines and missed
# lines, and each file row starts with <Module>/<File>.swift.
modules=$(echo "$report" | awk '
    $1 ~ /\.swift$/ { split($1, path, "/"); lines[path[1]] += $8; missed[path[1]] += $9 }
    END {
        for (m in lines) printf "| %s | %.1f%% | %d |\n", m, 100 * (lines[m] - missed[m]) / lines[m], lines[m]
    }' | sort)
line_total=$(echo "$report" | awk '$1 == "TOTAL" { print $10 }')

cat > "$out/summary.md" <<EOF
### $title

**$tests tests**: $((tests - failed - skipped)) passed, $failed failed, $skipped skipped.
Line coverage of \`TwinPanesKit/Sources\`: **$line_total**.

| Module | Line coverage | Lines |
| --- | ---: | ---: |
$modules
EOF

cat > "$out/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>:root { color-scheme: light dark; }
body { font: 15px -apple-system, system-ui, sans-serif; max-width: 700px; margin: 0 auto; padding: 16px; }
li { margin: 8px 0; }</style></head>
<body><h1>$title</h1><ul>
<li><a href="tests.html">Test results</a>: $tests tests, $failed failed, $skipped skipped</li>
<li><a href="coverage/index.html">Coverage</a>: $line_total of lines in TwinPanesKit/Sources</li>
</ul></body></html>
EOF
echo "Report written to $out"
