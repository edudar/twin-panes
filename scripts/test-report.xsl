<?xml version="1.0" encoding="UTF-8"?>
<!--
Turns the JUnit XML that swift test's xunit output option writes into one self-contained HTML
page. scripts/test-report.sh wraps every file it gets in a <runs> element first: Swift 6
writes one file for XCTest and one for Swift Testing, each with a <testsuite> per test
process. XSLT 1.0 because that is what macOS's xsltproc runs; the per-class grouping
uses the Muenchian key below.
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" indent="yes" doctype-system="about:legacy-compat"/>
  <xsl:param name="title" select="'Test results'"/>
  <xsl:key name="by-class" match="testcase" use="@classname"/>

  <xsl:variable name="cases" select="//testcase"/>
  <xsl:variable name="failed" select="$cases[failure or error]"/>
  <xsl:variable name="skipped" select="$cases[skipped]"/>

  <xsl:template match="/">
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title><xsl:value-of select="$title"/></title>
        <style>
          :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --muted: #6e6e73;
                  --line: #d2d2d7; --pass: #1a7f37; --fail: #cf222e; --skip: #9a6700; }
          @media (prefers-color-scheme: dark) {
            :root { --fg: #f5f5f7; --bg: #1c1c1e; --muted: #98989d; --line: #3a3a3c;
                    --pass: #3fb950; --fail: #f85149; --skip: #d29922; } }
          body { font: 14px -apple-system, system-ui, sans-serif; color: var(--fg);
                 background: var(--bg); margin: 0 auto; max-width: 1000px; padding: 16px; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin-top: 28px; }
          .totals span { margin-right: 18px; } .pass { color: var(--pass); }
          .fail { color: var(--fail); } .skip { color: var(--skip); } .muted { color: var(--muted); }
          table { border-collapse: collapse; width: 100%; }
          td, th { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--line); }
          td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
          details { border-bottom: 1px solid var(--line); padding: 4px 0; }
          summary { cursor: pointer; } pre { white-space: pre-wrap; font-size: 12px; }
          ul { margin: 4px 0 8px; padding-left: 20px; }
        </style>
      </head>
      <body>
        <h1><xsl:value-of select="$title"/></h1>
        <p class="totals">
          <span><b><xsl:value-of select="count($cases)"/></b> tests</span>
          <span class="pass"><xsl:value-of select="count($cases) - count($failed) - count($skipped)"/> passed</span>
          <span class="fail"><xsl:value-of select="count($failed)"/> failed</span>
          <span class="skip"><xsl:value-of select="count($skipped)"/> skipped</span>
        </p>
        <xsl:if test="$failed">
          <h2 class="fail">Failures</h2>
          <xsl:for-each select="$failed">
            <details open="">
              <summary><xsl:value-of select="@classname"/>.<b><xsl:value-of select="@name"/></b></summary>
              <pre><xsl:value-of select="(failure|error)/@message"/>
                <xsl:text>&#10;</xsl:text><xsl:value-of select="failure|error"/></pre>
            </details>
          </xsl:for-each>
        </xsl:if>
        <h2>By test class</h2>
        <xsl:for-each select="$cases[generate-id() = generate-id(key('by-class', @classname)[1])]">
          <xsl:sort select="@classname"/>
          <xsl:variable name="group" select="key('by-class', @classname)"/>
          <details>
            <summary>
              <xsl:value-of select="@classname"/>
              <span class="muted"> — <xsl:value-of select="count($group)"/> tests</span>
              <xsl:if test="$group[failure or error]">
                <span class="fail"> · <xsl:value-of select="count($group[failure or error])"/> failed</span>
              </xsl:if>
            </summary>
            <table>
              <xsl:for-each select="$group">
                <xsl:sort select="@name"/>
                <tr>
                  <td>
                    <xsl:choose>
                      <xsl:when test="failure or error"><span class="fail">✕</span></xsl:when>
                      <xsl:when test="skipped"><span class="skip">–</span></xsl:when>
                      <xsl:otherwise><span class="pass">✓</span></xsl:otherwise>
                    </xsl:choose>
                    <xsl:text> </xsl:text><xsl:value-of select="@name"/>
                  </td>
                  <td class="num muted"><xsl:value-of select="format-number(@time, '0.000')"/> s</td>
                </tr>
              </xsl:for-each>
            </table>
          </details>
        </xsl:for-each>
      </body>
    </html>
  </xsl:template>
</xsl:stylesheet>
