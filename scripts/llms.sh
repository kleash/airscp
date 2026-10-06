#!/bin/bash
# Writes docs/llms.txt (an index of AirSCP Help for AI agents, llmstxt.org) and docs/llms-full.txt (every page of the
# help, then the agent guide, in one plain file) from docs/*.md and Resources/AgentGuide.md. The site publishes both
# as they are (kleash.github.io/airscp/llms.txt). Run it after changing the docs: CI fails while they are out of date.
#   scripts/llms.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re

SITE = "https://kleash.github.io/airscp/"
REPO = "https://github.com/kleash/airscp"

def front_matter(text):
    lines = text.split("\n")
    if lines[0] != "---":
        return {}, text
    end = lines.index("---", 1)
    meta = {}
    for line in lines[1:end]:
        if ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip().strip("\"'")
    return meta, "\n".join(lines[end + 1:]).strip() + "\n"

def url(path):
    """docs/files/copy-files.md → …/files/copy-files.html; files/index.md → …/files/ (as GitHub Pages serves them)."""
    if path == "index.md":
        return SITE
    if path.endswith("/index.md"):
        return SITE + path[:-len("index.md")]
    return SITE + path[:-3] + ".html"

pages = {}
for folder, _, files in os.walk("docs"):
    for name in files:
        path = os.path.relpath(os.path.join(folder, name), "docs")
        if name.endswith(".md") and not path.startswith("dev/"):
            with open(os.path.join("docs", path), encoding="utf-8") as file:
                meta, body = front_matter(file.read())
            pages[path] = (meta, body)

def order(path):
    return int(pages[path][0].get("nav_order", 99))

# The site's navigation order: top-level pages, each category followed by its pages.
top = sorted((p for p, (m, _) in pages.items() if "parent" not in m), key=lambda p: (order(p), p))
ordered = []
for path in top:
    ordered.append(path)
    title = pages[path][0]["title"]
    ordered += sorted((p for p, (m, _) in pages.items() if m.get("parent") == title), key=lambda p: (order(p), p))

def plain(path, body):
    """The page as an agent reads it: pictures as their description, links as full URLs."""
    body = re.sub(r'\{%\s*include shot\.html name="[^"]+" alt="([^"]*)"\s*%\}', r"(Picture: \1)", body)
    folder = os.path.dirname(path)
    def link(match):
        target, anchor = (match.group(2).split("#", 1) + [""])[:2]
        if "://" in target or target.startswith("mailto:") or not target.endswith(".md"):
            return match.group(0)
        full = url(os.path.normpath(os.path.join(folder, target)))
        return f"]({full}{'#' + anchor if anchor else ''})"
    return re.sub(r"\]\(()([^)\s]+)\)", link, body)

def summary(body):
    """The page's first paragraph after its title (what the page is for), on one line; none when it starts with steps."""
    blocks = [block.strip() for block in body.split("\n\n") if block.strip()]
    first = next((block for block in blocks if not block.startswith("# ")), "")
    if first.startswith(("#", "{%", "|", "-", "!", "<")) or re.match(r"\d+\.", first):
        return ""
    return " ".join(plain("", first).split())

intro = (
    "# AirSCP\n\n"
    "> AirSCP is a free, open-source Mac app (macOS 13.1 or later) for SSH servers and Windows desktops: saved hosts, "
    "a two-pane SCP/SFTP file browser with a background transfer queue, Synchronize, Find Files, remote file "
    "operations, a Linux monitor, tunnels, jump hosts and HTTP proxies, and a built-in Remote Desktop client with "
    "clipboard and file transfer. AI agents drive it over MCP once the user allows it.\n\n"
    "- Install: `brew install --cask kleash/tap/airscp` (or the zip from " + REPO + "/releases).\n"
    "- Agent control: the user turns on AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP (MCP); then "
    "`claude mcp add airscp -- /Applications/AirSCP.app/Contents/MacOS/AirSCP --mcp` (any MCP client: that "
    "program with `--mcp`, over stdio). Or the Claude Code plugin: `/plugin marketplace add kleash/airscp`, then "
    "`/plugin install airscp@airscp`.\n"
    "- Driving it: `snapshot` → one action (`menu`, `press`, `set`, `select`, `drop`) → `wait` → `snapshot`. "
    "AirSCP's questions (Trust, passwords, Replace, Delete) come back as a `sheet` to answer. The `guide` tool has "
    "every tool and a recipe per feature; agents never see saved passwords.\n"
)

def entry(path):
    meta, body = pages[path]
    note = summary(body)
    return f"- [{meta['title']}]({url(path)})" + (f": {note}" if note else "") + "\n"

# Each category with its pages, then the pages that stand alone.
index = [intro]
for path in top:
    if pages[path][0].get("has_children") == "true":
        title = pages[path][0]["title"]
        index.append(f"\n## {title}\n")
        index += [entry(p) for p in ordered if p == path or pages[p][0].get("parent") == title]
index.append("\n## More topics\n")
index += [entry(p) for p in top if pages[p][0].get("has_children") != "true"]
index.append(
    "\n## For agents\n"
    f"- [Agent guide]({REPO}/blob/main/Resources/AgentGuide.md): every MCP tool with an example, and a recipe per "
    "feature (the same text as the MCP server's instructions and its `guide` tool)\n"
    f"- [AGENTS.md]({REPO}/blob/main/AGENTS.md): install, enable and connect in five lines\n"
    f"- [All of the help in one file]({SITE}llms-full.txt)\n"
    "\n## Optional\n"
    f"- [Source code]({REPO}): Swift, Apache 2.0\n"
    f"- [Report a problem]({REPO}/issues/new?template=bug_report.yml)\n"
)
with open("docs/llms.txt", "w", encoding="utf-8") as file:
    file.write("".join(index))

full = [intro.replace("# AirSCP\n", "# AirSCP Help (all pages)\n", 1),
        f"\nEvery page of AirSCP Help ({SITE}), then the agent guide.\n"]
for path in ordered:
    meta, body = pages[path]
    full.append(f"\n\n---\n\nSource: {url(path)}\n\n" + plain(path, body))
with open("Resources/AgentGuide.md", encoding="utf-8") as file:
    full.append(f"\n\n---\n\nSource: {REPO}/blob/main/Resources/AgentGuide.md\n\n" + file.read())
with open("docs/llms-full.txt", "w", encoding="utf-8") as file:
    file.write("".join(full).rstrip() + "\n")
print(f"docs/llms.txt and docs/llms-full.txt: {len(ordered)} pages and the agent guide")
PY
