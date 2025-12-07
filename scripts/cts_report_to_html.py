#!/usr/bin/env python3

"""
Credits to Arthur Vasseur for this script.

https://github.com/ArthurVasseur/Vkd/blob/main/scripts/cts_report.py
"""

import sys
import re
import os
import math
import xml.etree.ElementTree as ET
import pandas as pd
from datetime import datetime
from collections import Counter

PAGE_SIZE = 100

def parse_raw_log(log_text: str):
    """Extract <TestCaseResult> XML blocks from a raw CTS log file."""
    pattern = re.compile(
        r'<TestCaseResult[^>]*>.*?</TestCaseResult>',
        re.DOTALL
    )
    matches = pattern.findall(log_text)
    return matches


def parse_xml_file(path: str):
    """Extract <TestCaseResult> nodes from a pure XML file."""
    tree = ET.parse(path)
    root = tree.getroot()
    return [
        ET.tostring(elem, encoding="unicode")
        for elem in root.findall(".//TestCaseResult")
    ]


def process_testcases(xml_blocks):
    """Convert XML test blocks into structured rows."""
    rows = []

    for block in xml_blocks:
        elem = ET.fromstring(block)

        case = elem.attrib.get("CasePath", "unknown")
        duration = elem.findtext("Number", default="0")
        result = elem.find("Result").attrib.get("StatusCode", "UNKNOWN")
        message = elem.findtext("Text", default="")

        rows.append({
            "Test Case": case,
            "Duration (µs)": int(duration),
            "Status": result,
            "Message": message,
            "RawMessage": message,
        })

    return rows

def format_message_html(message: str) -> str:
    """Format test message for HTML display with proper handling of newlines and tabs."""
    if not message:
        return ""

    import html
    import json
    import textwrap

    try:
        formatted = bytes(message, 'utf-8').decode('unicode_escape')
    except Exception:
        formatted = message
        for old, new in [('\\n', '\n'), ('\\t', '\t'), ('\\r', '\r')]:
            formatted = formatted.replace(old, new)

    formatted = textwrap.dedent(formatted).strip()

    try:
        if formatted.strip().startswith('{') or formatted.strip().startswith('['):
            parsed = json.loads(formatted)
            formatted = json.dumps(parsed, indent=2)
            escaped = html.escape(formatted)
            return f'<details class="message-details"><summary>View JSON</summary><pre class="message-pre message-json">{escaped}</pre></details>'
    except (json.JSONDecodeError, ValueError):
        pass

    if '\n' in formatted or '\t' in formatted or len(message) > 100:
        escaped = html.escape(formatted)
        return f'<details class="message-details"><summary>View details</summary><pre class="message-pre">{escaped}</pre></details>'
    else:
        return html.escape(formatted)

def status_to_html(status: str) -> str:
    cls = {
        "Pass": "status-Pass",
        "Fail": "status-Fail",
        "NotSupported": "status-NotSupported",
    }.get(status, "")
    return f'<span class="status-pill {cls}">{status}</span>'

def calculate_statistics(df):
    """Calculate test statistics from the dataframe."""
    status_counts = Counter(df['Status'])
    total_tests = len(df)
    total_duration = df['Duration (µs)'].sum()
    avg_duration = df['Duration (µs)'].mean() if total_tests > 0 else 0

    pass_count = status_counts.get('Pass', 0)
    fail_count = status_counts.get('Fail', 0)
    not_supported_count = status_counts.get('NotSupported', 0)
    other_count = total_tests - (pass_count + fail_count + not_supported_count)

    pass_rate = (pass_count / total_tests * 100) if total_tests > 0 else 0

    return {
        'total': total_tests,
        'pass': pass_count,
        'fail': fail_count,
        'not_supported': not_supported_count,
        'other': other_count,
        'pass_rate': pass_rate,
        'total_duration_us': total_duration,
        'total_duration_ms': total_duration / 1000,
        'total_duration_s': total_duration / 1_000_000,
        'avg_duration_us': avg_duration,
    }

def generate_pie_chart_svg(stats):
    """Generate a simple SVG pie chart for test results."""
    total = stats['total']
    if total == 0:
        return ""

    pass_pct = stats['pass'] / total
    fail_pct = stats['fail'] / total
    not_supported_pct = stats['not_supported'] / total
    other_pct = stats['other'] / total

    segments = []
    cumulative = 0

    colors = {
        'pass': '#22c55e',
        'fail': '#f97373',
        'not_supported': '#eab308',
        'other': '#64748b'
    }

    for name, pct, color in [
        ('Pass', pass_pct, colors['pass']),
        ('Fail', fail_pct, colors['fail']),
        ('Not Supported', not_supported_pct, colors['not_supported']),
        ('Other', other_pct, colors['other'])
    ]:
        if pct > 0:
            segments.append({
                'name': name,
                'percentage': pct * 100,
                'start': cumulative,
                'end': cumulative + pct,
                'color': color
            })
            cumulative += pct

    svg_paths = []
    radius = 80
    cx, cy = 100, 100

    for seg in segments:
        start_angle = seg['start'] * 2 * 3.14159
        end_angle = seg['end'] * 2 * 3.14159

        x1 = cx + radius * cos_approx(start_angle)
        y1 = cy + radius * sin_approx(start_angle)
        x2 = cx + radius * cos_approx(end_angle)
        y2 = cy + radius * sin_approx(end_angle)

        large_arc = 1 if (end_angle - start_angle) > 3.14159 else 0

        path = f'M {cx} {cy} L {x1} {y1} A {radius} {radius} 0 {large_arc} 1 {x2} {y2} Z'
        svg_paths.append(f'<path d="{path}" fill="{seg["color"]}" opacity="0.9" stroke="rgba(255,255,255,0.1)" stroke-width="1"/>')

    return f'''
    <svg viewBox="0 0 200 200" class="pie-chart">
        {chr(10).join(svg_paths)}
    </svg>
    '''

def cos_approx(angle):
    import math
    return math.cos(angle)

def sin_approx(angle):
    import math
    return math.sin(angle)

def build_pagination(page_num: int, num_pages: int, base_output: str) -> str:
    """
    base_output: basename used for files, e.g. 'report' -> report_page_1.html
    """
    window = 2  # how many pages before/after the current one to show
    links = []

    # First / Prev
    if page_num > 1:
        links.append(f'<a href="{base_output}_page_1.html" class="pag-link">First</a>')
        links.append(
            f'<a href="{base_output}_page_{page_num-1}.html" class="pag-link">Prev</a>'
        )
    else:
        links.append('<span class="pag-link disabled">First</span>')
        links.append('<span class="pag-link disabled">Prev</span>')

    # Page range around current
    start_page = max(1, page_num - window)
    end_page = min(num_pages, page_num + window)

    # Ellipsis before
    if start_page > 1:
        links.append('<span class="pag-ellipsis">…</span>')

    for p in range(start_page, end_page + 1):
        if p == page_num:
            links.append(f'<span class="pag-link active">{p}</span>')
        else:
            links.append(
                f'<a href="{base_output}_page_{p}.html" class="pag-link">{p}</a>'
            )

    # Ellipsis after
    if end_page < num_pages:
        links.append('<span class="pag-ellipsis">…</span>')

    # Next / Last
    if page_num < num_pages:
        links.append(
            f'<a href="{base_output}_page_{page_num+1}.html" class="pag-link">Next</a>'
        )
        links.append(
            f'<a href="{base_output}_page_{num_pages}.html" class="pag-link">Last</a>'
        )
    else:
        links.append('<span class="pag-link disabled">Next</span>')
        links.append('<span class="pag-link disabled">Last</span>')

    return f"""
    <nav class="pagination">
      <span class="pagination-summary">Page {page_num} of {num_pages}</span>
      <div class="pagination-links">
        {' '.join(links)}
      </div>
    </nav>
    """

def main():
    if len(sys.argv) != 3:
        print("Usage: cts_report.py <input_log_or_xml> <output_html>")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    if not os.path.exists(input_path):
        print(f"Error: input file not found: {input_path}")
        sys.exit(1)

    # Detect input format
    with open(input_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    if "<TestCaseResult" in content and content.strip().startswith("<?xml"):
        print("[INFO] Detected pure XML input")
        xml_blocks = parse_xml_file(input_path)
    else:
        print("[INFO] Detected raw CTS log input")
        xml_blocks = parse_raw_log(content)

    if not xml_blocks:
        print("Error: no TestCaseResult entries found.")
        sys.exit(1)

    rows = process_testcases(xml_blocks)

    df = pd.DataFrame(rows)

    total_tests = len(df)
    num_pages = math.ceil(total_tests / PAGE_SIZE)

    # Calculate statistics before converting status to HTML
    stats = calculate_statistics(df)

    df["Status"] = df["Status"].apply(status_to_html)

    # Store formatted messages separately to avoid pandas escaping
    formatted_messages = df["Message"].apply(format_message_html).tolist()
    df["Message"] = [f"__MSG_PLACEHOLDER_{i}__" for i in range(len(df))]

    if "RawMessage" in df.columns:
        df = df.drop(columns=["RawMessage"])

    pie_chart_svg = generate_pie_chart_svg(stats)

    generation_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    if stats['total_duration_s'] > 1:
        duration_str = f"{stats['total_duration_s']:.2f}s"
    else:
        duration_str = f"{stats['total_duration_ms']:.2f}ms"

    base_output = os.path.splitext(output_path)[0]  # e.g. "report"

    for page_index in range(num_pages):
        start = page_index * PAGE_SIZE
        end = min(start + PAGE_SIZE, total_tests)
        df_page = df.iloc[start:end]

        # recreate placeholders & table for this page
        formatted_messages_page = formatted_messages[start:end]
        df_page["Message"] = [f"__MSG_PLACEHOLDER_{i}__" for i in range(start, end)]
        table_html = df_page.to_html(
            index=False,
            escape=False,
            justify="center",
            border=0,
            classes="cts-table",
            table_id="results-table"
        )

        # Replace placeholders for this chunk
        for i in range(start, end):
            table_html = table_html.replace(
                f"__MSG_PLACEHOLDER_{i}__", formatted_messages[i]
            )

        # Page numbering (1-based for humans)
        page_num = page_index + 1
        page_title_suffix = f" – Page {page_num}/{num_pages}"

        # Simple HTML navigation (pure HTML, no JS)
        pagination_nav = build_pagination(page_num, num_pages, base_output)

        page_html = f"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Vulkan CTS Report{page_title_suffix}</title>
<style>
:root {{
    --bg: #0f172a;
    --bg-card: #020617;
    --bg-card-soft: #02081f;
    --accent: #38bdf8;
    --accent-soft: rgba(56, 189, 248, 0.15);
    --accent-strong: #0ea5e9;
    --text-main: #e5e7eb;
    --text-muted: #9ca3af;
    --border-soft: rgba(148, 163, 184, 0.2);
    --danger: #f97373;
    --warning: #eab308;
    --success: #22c55e;
    --radius-lg: 14px;
    --radius-pill: 999px;
    --shadow-soft: 0 18px 45px rgba(15, 23, 42, 0.65);
    --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
}}

* {{
    box-sizing: border-box;
}}

html, body {{
    margin: 0;
    padding: 0;
    background: radial-gradient(circle at top, #1e293b 0, #020617 45%, #000 100%);
    color: var(--text-main);
    font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}}

body {{
    min-height: 100vh;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    padding: 40px 16px;
}}

.report-shell {{
    width: 100%;
    max-width: 1400px;
}}

.report-card {{
    background: linear-gradient(145deg, var(--bg-card) 0, var(--bg-card-soft) 60%, #020617 100%);
    border-radius: 24px;
    box-shadow: var(--shadow-soft);
    padding: 24px 24px 18px;
    border: 1px solid rgba(148, 163, 184, 0.20);
    backdrop-filter: blur(12px);
    margin-bottom: 24px;
}}

.report-header {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 16px;
    margin-bottom: 18px;
}}

.report-title-block h1 {{
    font-size: 1.5rem;
    margin: 0 0 4px;
    letter-spacing: 0.02em;
}}

.report-title-block .subtitle {{
    margin: 0;
    font-size: 0.9rem;
    color: var(--text-muted);
}}

.report-meta {{
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    justify-content: flex-end;
    align-items: center;
}}

.badge {{
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 10px;
    border-radius: var(--radius-pill);
    font-size: 0.8rem;
    border: 1px solid rgba(148, 163, 184, 0.35);
    background: rgba(15, 23, 42, 0.85);
    color: var(--text-muted);
}}

.badge-dot {{
    width: 7px;
    height: 7px;
    border-radius: 999px;
    background: var(--accent);
}}

.badge-accent {{
    border-color: rgba(56, 189, 248, 0.45);
    background: var(--accent-soft);
    color: var(--accent-strong);
}}

.stats-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px;
    margin-bottom: 24px;
}}

.stat-card {{
    background: rgba(15, 23, 42, 0.5);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-lg);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 8px;
}}

.stat-card-header {{
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--text-muted);
    font-size: 0.85rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
}}

.stat-icon {{
    width: 20px;
    height: 20px;
    border-radius: 50%;
}}

.stat-value {{
    font-size: 2rem;
    font-weight: 600;
    line-height: 1;
}}

.stat-label {{
    font-size: 0.8rem;
    color: var(--text-muted);
}}

.stat-success {{ color: var(--success); }}
.stat-danger {{ color: var(--danger); }}
.stat-warning {{ color: var(--warning); }}
.stat-info {{ color: var(--accent); }}

.chart-container {{
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 20px;
    background: rgba(15, 23, 42, 0.3);
    border-radius: var(--radius-lg);
    margin-bottom: 24px;
}}

.pie-chart {{
    max-width: 200px;
    height: auto;
}}

.search-container {{
    margin-bottom: 16px;
}}

.search-input {{
    width: 100%;
    padding: 10px 16px;
    background: rgba(15, 23, 42, 0.85);
    border: 1px solid var(--border-soft);
    border-radius: var(--radius-lg);
    color: var(--text-main);
    font-size: 0.9rem;
    font-family: inherit;
    transition: border-color 0.2s ease;
}}

.search-input:focus {{
    outline: none;
    border-color: var(--accent);
    background: rgba(15, 23, 42, 0.95);
}}

.search-input::placeholder {{
    color: var(--text-muted);
}}

.table-wrapper {{
    margin-top: 16px;
    border-radius: var(--radius-lg);
    border: 1px solid var(--border-soft);
    overflow: hidden;
    background: rgba(15, 23, 42, 0.85);
}}

.cts-table {{
    width: 100%;
    border-collapse: collapse;
    border-spacing: 0;
    font-size: 0.9rem;
}}

.cts-table thead {{
    background: radial-gradient(circle at top, rgba(56, 189, 248, 0.1), rgba(15, 23, 42, 1));
}}

.cts-table thead th {{
    padding: 10px 12px;
    text-align: left;
    border-bottom: 1px solid var(--border-soft);
    font-weight: 500;
    color: var(--text-muted);
    font-size: 0.8rem;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    white-space: nowrap;
}}

.cts-table tbody tr {{
    transition: background 0.18s ease, transform 0.08s ease;
}}

.cts-table tbody tr:nth-child(even) {{
    background: rgba(15, 23, 42, 0.95);
}}

.cts-table tbody tr:nth-child(odd) {{
    background: rgba(15, 23, 42, 0.85);
}}

.cts-table tbody tr:hover {{
    background: rgba(56, 189, 248, 0.07);
}}

.cts-table td {{
    padding: 8px 12px;
    border-bottom: 1px solid rgba(15, 23, 42, 0.9);
    vertical-align: top;
}}

.cts-table td:first-child {{
    font-family: var(--font-mono);
    font-size: 0.82rem;
    color: #e2e8f0;
}}

.cts-table td:nth-child(2) {{
    white-space: nowrap;
}}

.cts-table td:nth-child(3) {{
    width: 1%;
    white-space: nowrap;
}}

.cts-table td:last-child {{
    color: var(--text-muted);
}}

.status-pill {{
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 2px 10px;
    border-radius: var(--radius-pill);
    font-size: 0.75rem;
    font-weight: 500;
    border: 1px solid transparent;
}}

.status-Pass {{
    background: rgba(34, 197, 94, 0.12);
    border-color: rgba(34, 197, 94, 0.55);
    color: var(--success);
}}

.status-Fail {{
    background: rgba(248, 113, 113, 0.12);
    border-color: rgba(248, 113, 113, 0.55);
    color: var(--danger);
}}

.status-NotSupported {{
    background: rgba(234, 179, 8, 0.12);
    border-color: rgba(234, 179, 8, 0.55);
    color: var(--warning);
}}

.footer-note {{
    margin-top: 12px;
    font-size: 0.78rem;
    color: var(--text-muted);
    text-align: right;
}}

.footer-note code {{
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: #cbd5f5;
}}

.hidden {{
    display: none !important;
}}

.message-details {{
    margin: 4px 0;
}}

.message-details summary {{
    cursor: pointer;
    color: var(--accent);
    font-size: 0.85rem;
    padding: 4px 8px;
    border-radius: 4px;
    display: inline-block;
    transition: background 0.2s ease;
}}

.message-details summary:hover {{
    background: var(--accent-soft);
}}

.message-details[open] summary {{
    margin-bottom: 8px;
}}

.message-pre {{
    background: rgba(0, 0, 0, 0.4);
    border: 1px solid var(--border-soft);
    border-radius: 8px;
    padding: 12px;
    margin: 0;
    overflow-x: auto;
    font-family: var(--font-mono);
    font-size: 0.8rem;
    line-height: 1.5;
    color: #e2e8f0;
    white-space: pre-wrap;
    word-wrap: break-word;
    max-height: 400px;
    overflow-y: auto;
}}

.message-pre::-webkit-scrollbar {{
    width: 8px;
    height: 8px;
}}

.message-pre::-webkit-scrollbar-track {{
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
}}

.message-pre::-webkit-scrollbar-thumb {{
    background: rgba(148, 163, 184, 0.3);
    border-radius: 4px;
}}

.message-pre::-webkit-scrollbar-thumb:hover {{
    background: rgba(148, 163, 184, 0.5);
}}

.pagination {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin: 12px 0;
    font-size: 0.85rem;
}}

.pagination-summary {{
    color: var(--text-muted);
}}

.pagination-links {{
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
}}

.pag-link,
.pag-ellipsis {{
    display: inline-block;
    padding: 4px 10px;
    border-radius: 999px;
    font-size: 0.85rem;
}}

.pag-link {{
    text-decoration: none;
    border: 1px solid rgba(148, 163, 184, 0.35);
    color: var(--text-muted);
    background: rgba(15, 23, 42, 0.9);
    transition: background 0.15s ease, border-color 0.15s ease, color 0.15s ease;
}}

.pag-link:hover {{
    background: var(--accent-soft);
    border-color: var(--accent);
    color: var(--accent-strong);
}}

.pag-link.active {{
    background: var(--accent-soft);
    border-color: var(--accent);
    color: var(--accent-strong);
    cursor: default;
}}

.pag-link.disabled {{
    opacity: 0.4;
    border-style: dashed;
    cursor: not-allowed;
    pointer-events: none;
}}

.pag-ellipsis {{
    color: var(--text-muted);
    padding: 4px 2px;
}}
</style>
</head>
<body>
<div class="report-shell">
  <div class="report-card">
    <div class="report-header">
      <div class="report-title-block">
        <h1>Vulkan CTS Report</h1>
        <p class="subtitle">Summary of test cases, status and timings</p>
      </div>
      <div class="report-meta">
        <div class="badge badge-accent">
          <span class="badge-dot"></span>
          <span>{generation_time}</span>
        </div>
        <div class="badge">
          <span class="badge-dot" style="background: #4ade80;"></span>
          <span>Total: {stats['total']} tests</span>
        </div>
      </div>
    </div>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-card-header">
          <div class="stat-icon" style="background: var(--success);"></div>
          <span>Passed</span>
        </div>
        <div class="stat-value stat-success">{stats['pass']}</div>
        <div class="stat-label">{stats['pass_rate']:.1f}% success rate</div>
      </div>

      <div class="stat-card">
        <div class="stat-card-header">
          <div class="stat-icon" style="background: var(--danger);"></div>
          <span>Failed</span>
        </div>
        <div class="stat-value stat-danger">{stats['fail']}</div>
        <div class="stat-label">{(stats['fail'] / stats['total'] * 100) if stats['total'] > 0 else 0:.1f}% of total</div>
      </div>

      <div class="stat-card">
        <div class="stat-card-header">
          <div class="stat-icon" style="background: var(--warning);"></div>
          <span>Not Supported</span>
        </div>
        <div class="stat-value stat-warning">{stats['not_supported']}</div>
        <div class="stat-label">{(stats['not_supported'] / stats['total'] * 100) if stats['total'] > 0 else 0:.1f}% of total</div>
      </div>

      <div class="stat-card">
        <div class="stat-card-header">
          <div class="stat-icon" style="background: var(--accent);"></div>
          <span>Duration</span>
        </div>
        <div class="stat-value stat-info">{duration_str}</div>
        <div class="stat-label">Avg: {stats['avg_duration_us']:.0f} µs/test</div>
      </div>
    </div>

    <div class="chart-container">
      {pie_chart_svg}
    </div>

    {pagination_nav}

    <div class="table-wrapper">
      {table_html}
    </div>

    <div class="footer-note">
        Generated by
        <a href="https://github.com/Kbz-8/VulkanDriver/blob/master/scripts/cts_report_to_html.py">
            <code>cts_report.py</code>
        </a>
        at {generation_time}
    </div>
  </div>
</div>

<script>
function filterTable() {{
    const input = document.getElementById('search-input');
    const filter = input.value.toLowerCase();
    const table = document.getElementById('results-table');
    const tbody = table.getElementsByTagName('tbody')[0];
    const rows = tbody.getElementsByTagName('tr');

    for (let i = 0; i < rows.length; i++) {{
        const cells = rows[i].getElementsByTagName('td');
        let found = false;

        for (let j = 0; j < cells.length; j++) {{
            const cell = cells[j];
            if (cell) {{
                const textValue = cell.textContent || cell.innerText;
                if (textValue.toLowerCase().indexOf(filter) > -1) {{
                    found = true;
                    break;
                }}
            }}
        }}

        if (found) {{
            rows[i].classList.remove('hidden');
        }} else {{
            rows[i].classList.add('hidden');
        }}
    }}
}}
</script>
</body>
</html>
"""
        page_output_path = f"cts_report/{base_output}_page_{page_num}.html"

        os.makedirs(os.path.dirname(page_output_path), exist_ok=True)
        with open(page_output_path, "w", encoding="utf-8") as f:
            f.write(page_html)

    print(f"[OK] HTML report saved to: {output_path}")
    print(f"\n--- Test Statistics ---")
    print(f"Total tests:      {stats['total']}")
    print(f"Passed:           {stats['pass']} ({stats['pass_rate']:.1f}%)")
    print(f"Failed:           {stats['fail']} ({(stats['fail'] / stats['total'] * 100) if stats['total'] > 0 else 0:.1f}%)")
    print(f"Not Supported:    {stats['not_supported']} ({(stats['not_supported'] / stats['total'] * 100) if stats['total'] > 0 else 0:.1f}%)")
    if stats['other'] > 0:
        print(f"Other:            {stats['other']} ({(stats['other'] / stats['total'] * 100) if stats['total'] > 0 else 0:.1f}%)")
    print(f"Total Duration:   {duration_str}")
    print(f"Average Duration: {stats['avg_duration_us']:.0f} µs/test")


if __name__ == "__main__":
    main()
