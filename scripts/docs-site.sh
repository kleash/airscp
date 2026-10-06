#!/bin/bash
# Builds AirSCP Help (docs/) the way GitHub Pages does, and checks every link and picture of the result.
#   scripts/docs-site.sh          builds it into build/docs-site/airscp and checks it
#   scripts/docs-site.sh serve    the same, then serves it at http://localhost:4000/airscp/ (Ctrl-C stops it)
# Needs Docker Desktop and, the first time, the internet: GitHub Pages' own build image (Ruby, the github-pages gem and
# its plugins, all fixed by the image's digest) is downloaded once, and the theme comes from GitHub at every build. The
# image is for Intel; on Apple silicon Docker emulates it. ./test.sh checks the Markdown sources offline as well
# (Tests/AirSCPTests/DocsTests.swift).
set -euo pipefail
cd "$(dirname "$0")/.."

docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker
# The image of actions/jekyll-build-pages v1.0.13, which builds GitHub Pages sites: move the pin when that action moves.
image=ghcr.io/actions/jekyll-build-pages:v1.0.13@sha256:6791ebfd912185ed59bfb5fb102664fa872496b79f87ff8b9cfba292a7345041
run=("$docker" run --rm --platform linux/amd64)

out=build/docs-site
rm -rf "$out"
mkdir -p "$out"
# From a copy, in its folder: jekyll-relative-links resolves links against the folder it runs in, and Sass writes its
# cache there.
"${run[@]}" -v "$PWD/docs:/docs:ro" -v "$PWD/$out:/out" -e JEKYLL_ENV=production -e PAGES_REPO_NWO=kleash/airscp \
    --entrypoint sh "$image" -c 'cp -R /docs /site && cd /site && jekyll build --destination /out/airscp --baseurl /airscp'

# Every link and picture of every page leads to a file of the site (and an anchor to an id on that page).
python3 - "$out" <<'PY'
import os, sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse, unquote

root = sys.argv[1]

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for key in ("href", "src", "srcset"):
            if attrs.get(key) and not (tag == "link" and attrs.get("rel") in ("canonical",)):
                self.links.append(attrs[key].split()[0])

def parse(path):
    page = Page()
    with open(path, encoding="utf-8") as file:
        page.feed(file.read())
    return page

def target(url_path):
    path = os.path.join(root, unquote(url_path).lstrip("/"))
    if os.path.isdir(path):
        path = os.path.join(path, "index.html")
    elif not os.path.exists(path) and os.path.exists(path + ".html"):
        path += ".html"
    return path

pages = {}
problems = []
for folder, _, files in os.walk(root):
    for name in files:
        if name.endswith(".html"):
            path = os.path.join(folder, name)
            pages[path] = parse(path)
for path, page in sorted(pages.items()):
    base = "/" + os.path.relpath(path, root)
    for link in page.links:
        url = urlparse(urljoin(base, link))
        if url.scheme in ("http", "https", "mailto", "data") or link.startswith("//"):
            continue
        file = target(url.path)
        if not os.path.exists(file):
            problems.append(f"{base}: {link} leads nowhere")
        elif url.fragment and file in pages and url.fragment not in pages[file].ids:
            problems.append(f"{base}: no #{url.fragment} in {url.path}")
    # HTML shown as text: an include indented inside a list step became a code block.
    with open(path, encoding="utf-8") as file:
        if any(tag in file.read() for tag in ("&lt;/figure", "&lt;/picture", "&lt;img ")):
            problems.append(f"{base}: shows HTML tags as text")
if problems:
    print("\n".join(problems))
    sys.exit(f"{len(problems)} broken links in AirSCP Help")
print(f"AirSCP Help: {len(pages)} pages, every link and picture leads somewhere.")
PY

if [[ ${1:-} == serve ]]; then
    echo "AirSCP Help: http://localhost:4000/airscp/ (Ctrl-C stops it)"
    "${run[@]}" -p 127.0.0.1:4000:4000 -v "$PWD/$out:/out:ro" --entrypoint ruby "$image" -run -e httpd /out -p 4000 -b 0.0.0.0
fi
