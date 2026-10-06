import AppKit
import Foundation
import Testing
@testable import AirSCP

// PLAN.md Y: AirSCP Help (docs/, the GitHub Pages site) and the app agree. Every page the app opens (the Help menu,
// the sheets' "?" buttons) is a page of docs/; every link and picture in docs/ leads somewhere; every picture is used;
// and every menu command is named in the docs.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().path
private let docs = repo + "/docs"

/// The help's pages, by path below docs/ ("files/copy-files.md"): every Markdown file but the developers' notes
/// (dev/, which _config.yml leaves out of the site).
private func pages() throws -> [String: String] {
    var result: [String: String] = [:]
    for case let path as String in FileManager.default.enumerator(atPath: docs) ?? FileManager.DirectoryEnumerator()
    where path.hasSuffix(".md") && !path.hasPrefix("dev/") {
        result[path] = try String(contentsOfFile: docs + "/" + path, encoding: .utf8)
    }
    return result
}

/// A page's front matter (key: value lines between the first two "---").
private func frontMatter(_ text: String) -> [String: String] {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
    var result: [String: String] = [:]
    for line in lines[1..<end] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        result[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return result
}

/// The ids of a page's headings, as kramdown (GitHub Pages) makes them: lower case, punctuation dropped, spaces as "-".
private func anchors(_ text: String) -> Set<String> {
    Set(text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }.map { line in
        let words = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
        return String(words.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) }
            .map(Character.init)).replacingOccurrences(of: " ", with: "-")
    })
}

private func matches(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

@Test func everyHelpPageTheAppOpensIsInTheDocs() throws {
    let all = try pages()
    #expect(HelpPage.site.absoluteString == "https://kleash.github.io/airscp/")
    for page in HelpPage.allCases {
        // "keys/new-key-pair.html" is keys/new-key-pair.md, "files/" files/index.md, "" index.md.
        let parts = page.rawValue.components(separatedBy: "#")
        var file = parts[0].isEmpty || parts[0].hasSuffix("/") ? parts[0] + "index.md" : parts[0]
        if file.hasSuffix(".html") { file = String(file.dropLast(5)) + ".md" }
        #expect(page.url.absoluteString == HelpPage.site.absoluteString + page.rawValue, "\(page) opens \(page.url)")
        #expect(all[file] != nil, "\(page) opens \(page.url), but docs/\(file) doesn't exist")
        if parts.count > 1, let text = all[file] { #expect(anchors(text).contains(parts[1]), "\(page): no heading #\(parts[1])") }
    }
    #expect(HelpPage.reportProblem.absoluteString.hasPrefix("https://github.com/kleash/airscp/issues/new?template=bug_report.yml"))
    #expect(FileManager.default.fileExists(atPath: repo + "/.github/ISSUE_TEMPLATE/bug_report.yml"))
}

/// The link check: every relative link (page or anchor) and picture in the help leads somewhere, every page has its
/// title and, in a category, a parent page by that title; every picture in assets/shots is used (or the README's).
@Test func everyLinkAndPictureInTheDocsLeadsSomewhere() throws {
    let all = try pages()
    #expect(all.count > 40)
    let titles = Set(all.values.compactMap { frontMatter($0)["title"] })
    let parents = Set(all.values.filter { frontMatter($0)["has_children"] == "true" }.compactMap { frontMatter($0)["title"] })
    var used = Set<String>()
    for (path, text) in all.sorted(by: { $0.key < $1.key }) {
        let front = frontMatter(text)
        #expect(front["title"] != nil && front["nav_order"] != nil, "\(path): front matter needs a title and a nav_order")
        if let parent = front["parent"] { #expect(parents.contains(parent), "\(path): no category page titled “\(parent)”") }
        let folder = (path as NSString).deletingLastPathComponent
        for link in matches(#"\]\(([^)\s]+)\)"#, in: text) where !link.contains("://") && !link.hasPrefix("mailto:") {
            let parts = link.components(separatedBy: "#")
            let target = parts[0].isEmpty ? path : URL(fileURLWithPath: docs + "/" + folder).appendingPathComponent(parts[0])
                .standardized.path.replacingOccurrences(of: docs + "/", with: "")
            #expect(parts[0].isEmpty || parts[0].hasSuffix(".md"), "\(path): link \(link) isn't to a .md page")
            #expect(all[target] != nil, "\(path): link \(link) leads nowhere")
            if parts.count > 1, let page = all[target] { #expect(anchors(page).contains(parts[1]), "\(path): no heading for \(link)") }
        }
        for name in matches(#"\{%\s*include shot\.html name="([^"]+)""#, in: text) {
            used.insert(name)
            for mode in ["light", "dark"] {
                #expect(FileManager.default.fileExists(atPath: "\(docs)/assets/shots/\(name)-\(mode).png"), "\(path): no \(name)-\(mode).png")
            }
        }
    }
    #expect(titles.count == all.count, "two pages have the same title")
    let readme = (try? String(contentsOfFile: repo + "/README.md", encoding: .utf8)) ?? ""
    let shots = try FileManager.default.contentsOfDirectory(atPath: docs + "/assets/shots").filter { $0.hasSuffix(".png") }
    let unused = shots.filter { file in
        let name = file.replacingOccurrences(of: "-light.png", with: "").replacingOccurrences(of: "-dark.png", with: "")
        return !used.contains(name) && !readme.contains(file)
    }
    #expect(unused.isEmpty, "pictures no page uses (scripts/docs-screenshots.sh makes them): \(unused.sorted())")
}

/// Every menu command AirSCP adds is named somewhere in the help, so the help covers the whole app. AppKit's own
/// items (Undo, Hide Others, Services…) and the colour names are left out.
@MainActor @Test func theDocsNameEveryMenuCommand() throws {
    _ = NSApplication.shared
    _ = TestEnvironment.isolated
    let text = try pages().values.joined(separator: "\n").lowercased()
    let standard: Set<String> = ["undo", "redo", "cut", "copy", "paste", "select all", "minimize", "zoom", "hide airscp",
                                 "hide others", "show all", "quit airscp", "services", "close", "bring all to front",
                                 "about airscp", "airscp"]
    var missing: [String] = []
    func walk(_ menu: NSMenu, _ path: [String]) {
        for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty && !item.isHidden {
            let title = item.title.replacingOccurrences(of: "…", with: "").lowercased()
            if path.count > 0 && path.last != "Colour Tag" && !standard.contains(title) && !text.contains(title) {
                missing.append((path + [item.title]).joined(separator: " > "))
            }
            if let submenu = item.submenu, item.title != "Services" { walk(submenu, path + [item.title]) }
        }
    }
    walk(AppDelegate().mainMenu(), [])
    #expect(missing.isEmpty, "menu commands the docs don't name: \(missing)")
}
