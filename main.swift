import SwiftUI

extension String: @retroactive Error {}

struct PR: Identifiable {
    let id: Int
    let title: String
    let url: String
    let repo: String
    let position: String?
}

enum Bucket { case queued, failed }

@MainActor
final class Model: ObservableObject {
    @Published var queued: [PR] = []
    @Published var failed: [PR] = []
    @Published var mergedCount = 0
    @Published var merged: [PR] = []
    @Published var reviewCount = 0
    @Published var error: String?
    @Published var repos: [String] = UserDefaults.standard.stringArray(forKey: "repos") ?? []
    @Published var watched: [String] = UserDefaults.standard.stringArray(forKey: "watched") ?? []
    @Published var showMerged = UserDefaults.standard.bool(forKey: "showMerged")
    @Published var showReviews = UserDefaults.standard.bool(forKey: "showReviews")

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        refresh()
    }

    func save() {
        UserDefaults.standard.set(repos, forKey: "repos")
        UserDefaults.standard.set(watched, forKey: "watched")
        UserDefaults.standard.set(showMerged, forKey: "showMerged")
        UserDefaults.standard.set(showReviews, forKey: "showReviews")
    }

    func add(_ raw: String) {
        guard let slug = Self.slug(raw), !repos.contains(slug) else { return }
        repos.append(slug)
        save()
        refresh()
    }

    func remove(_ slug: String) {
        repos.removeAll { $0 == slug }
        save()
        refresh()
    }

    func addWatched(_ raw: String) {
        guard let ref = Self.prRef(raw), !watched.contains(ref) else { return }
        watched.append(ref)
        save()
        refresh()
    }

    func removeWatched(_ ref: String) {
        watched.removeAll { $0 == ref }
        save()
        refresh()
    }

    static func prRef(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = s.range(of: #"([\w.-]+)/([\w.-]+)(/pull/|#)(\d+)"#, options: .regularExpression)
        else { return nil }
        let hit = String(s[m])
        let parts = hit.split(whereSeparator: { $0 == "/" || $0 == "#" })
        guard parts.count >= 3, let n = Int(parts.last!) else { return nil }
        return "\(parts[0])/\(parts[1])#\(n)"
    }

    static func slug(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"] {
            if s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    var label: String {
        var bits = ["\(queued.count) ⏳"]
        if showMerged { bits.append("\(mergedCount) ✅") }
        bits.append("\(failed.count) ❌")
        if showReviews { bits.append("\(reviewCount) 👀") }
        return bits.joined(separator: " ")
    }

    func refresh() {
        repos = UserDefaults.standard.stringArray(forKey: "repos") ?? []
        watched = UserDefaults.standard.stringArray(forKey: "watched") ?? []
        let repos = self.repos
        let watched = self.watched
        guard !repos.isEmpty || !watched.isEmpty else {
            queued = []; failed = []; mergedCount = 0; reviewCount = 0; error = nil
            return
        }
        Task.detached {
            let result = Self.fetch(repos: repos, watched: watched)
            await MainActor.run {
                switch result {
                case .success(let (q, f, m, r, mg, staleRefs)):
                    self.queued = q; self.failed = f; self.mergedCount = m; self.reviewCount = r
                    self.merged = mg
                    self.error = nil
                    if !staleRefs.isEmpty {
                        self.watched.removeAll { staleRefs.contains($0) }
                        self.save()
                    }
                case .failure(let e):
                    self.error = e
                }
            }
        }
    }

    nonisolated private static func position(in body: String) -> String? {
        guard body.contains("zipper-queue-comment"),
              let r = body.range(of: #"Position \d+/\d+"#, options: .regularExpression)
        else { return nil }
        return String(body[r]).replacingOccurrences(of: "Position ", with: "")
    }

    nonisolated private static func fetch(repos: [String], watched: [String]) -> Result<([PR], [PR], Int, Int, [PR], [String]), String> {
        let scope = repos.map { "repo:\($0)" }.joined(separator: " ")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        let startOfToday = Calendar.current.startOfDay(for: Date())

        let prFields = """
        number title url repository { nameWithOwner } state mergedAt
        labels(first: 30) { nodes { name } }
        timelineItems(last: 50, itemTypes: [UNLABELED_EVENT]) {
          nodes { ... on UnlabeledEvent { createdAt label { name } } } }
        comments(last: 15) { nodes { body } }
        """

        var parts: [String] = []
        if !repos.isEmpty {
            parts.append("""
            open: search(query: "is:pr is:open author:@me \(scope)", type: ISSUE, first: 100) {
              nodes { ... on PullRequest { \(prFields) } } }
            merged: search(query: "is:pr is:merged author:@me merged:>=\(today) \(scope)", type: ISSUE, first: 1) {
              issueCount }
            review: search(query: "is:pr is:open user-review-requested:@me \(scope)", type: ISSUE, first: 1) {
              issueCount }
            """)
        }
        for (i, ref) in watched.enumerated() {
            let bits = ref.split(whereSeparator: { $0 == "/" || $0 == "#" })
            guard bits.count == 3, let n = Int(bits[2]) else { continue }
            parts.append("""
            w\(i): repository(owner: "\(bits[0])", name: "\(bits[1])") {
              pullRequest(number: \(n)) { \(prFields) } }
            """)
        }
        guard !parts.isEmpty else { return .success(([], [], 0, 0, [], [])) }
        let query = "{ " + parts.joined(separator: "\n") + " }"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh", "api", "graphql", "-f", "query=\(query)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failure("gh not found") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            return .failure(String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "gh failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any]
        else { return .failure("unexpected response") }

        var nodes = ((d["open"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        var mergedCount = ((d["merged"] as? [String: Any])?["issueCount"] as? Int) ?? 0
        let reviewCount = ((d["review"] as? [String: Any])?["issueCount"] as? Int) ?? 0

        let iso = ISO8601DateFormatter()
        var mergedPRs: [PR] = []
        var staleRefs: [String] = []

        for i in watched.indices {
            guard let n = (d["w\(i)"] as? [String: Any])?["pullRequest"] as? [String: Any] else { continue }
            switch n["state"] as? String {
            case "OPEN":
                nodes.append(n)
            case "MERGED":
                let isToday = (n["mergedAt"] as? String).flatMap(iso.date(from:)).map { $0 >= startOfToday } ?? false
                if isToday,
                   let number = n["number"] as? Int,
                   let title = n["title"] as? String,
                   let url = n["url"] as? String,
                   let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String {
                    mergedPRs.append(PR(id: number, title: title, url: url, repo: repo, position: nil))
                    mergedCount += 1
                } else {
                    staleRefs.append(watched[i])
                }
            default:
                break
            }
        }

        var queued: [PR] = [], failed: [PR] = []

        for n in nodes {
            guard let number = n["number"] as? Int,
                  let title = n["title"] as? String,
                  let url = n["url"] as? String,
                  let repo = (n["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { continue }
            let bodies = ((n["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
                .compactMap { $0["body"] as? String }
            let position = bodies.reversed().compactMap(Self.position).first
            let pr = PR(id: number, title: title, url: url, repo: repo, position: position)

            let labels = ((n["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            if labels.contains("automerge") { queued.append(pr); continue }

            let events = ((n["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
            let kickedToday = events.contains { e in
                guard (e["label"] as? [String: Any])?["name"] as? String == "automerge",
                      let at = e["createdAt"] as? String, let date = iso.date(from: at)
                else { return false }
                return date >= startOfToday
            }
            if kickedToday { failed.append(pr) }
        }

        return .success((queued, failed, mergedCount, reviewCount, mergedPRs, staleRefs))
    }
}

struct RepoSection: View {
    let repo: String
    let queued: [PR]
    let failed: [PR]
    let merged: [PR]

    var body: some View {
        if !queued.isEmpty || !failed.isEmpty || !merged.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(failed) { row("❌", $0) }
                ForEach(queued) { row("⏳", $0) }
                ForEach(merged) { row("✅", $0) }
            }
        }
    }

    func row(_ icon: String, _ pr: PR) -> some View {
        Link(destination: URL(string: pr.url)!) {
            HStack(alignment: .top, spacing: 6) {
                Text(icon)
                Text(verbatim: "#\(pr.id)")
                if let p = pr.position { Text(p).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
    }
}

final class Draft: ObservableObject {
    @Published var newRepo = ""
    @Published var newPR = ""
    @Published var showSettings = false
}

struct ContentView: View {
    @ObservedObject var model: Model
    @StateObject private var draft = Draft()

    var sections: [String] {
        var seen: [String] = []
        for repo in model.repos + (model.failed + model.queued + model.merged).map(\.repo)
        where !seen.contains(repo) { seen.append(repo) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = model.error {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if model.repos.isEmpty && model.watched.isEmpty {
                Text("Add a repo below.").foregroundStyle(.secondary)
            } else if model.queued.isEmpty && model.failed.isEmpty && model.merged.isEmpty {
                Text("Nothing in the queue.").foregroundStyle(.secondary)
            } else {
                ForEach(sections, id: \.self) { repo in
                    RepoSection(repo: repo,
                                queued: model.queued.filter { $0.repo == repo },
                                failed: model.failed.filter { $0.repo == repo },
                                merged: model.showMerged ? model.merged.filter { $0.repo == repo } : [])
                }
            }

            Divider()

            DisclosureGroup("Repos & PRs", isExpanded: $draft.showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.repos, id: \.self) { repo in
                        HStack {
                            Text(repo).font(.caption)
                            Spacer()
                            Button { model.remove(repo) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("paste repo URL", text: $draft.newRepo)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.add(draft.newRepo); draft.newRepo = "" }
                        Button("Add") { model.add(draft.newRepo); draft.newRepo = "" }
                    }
                    Divider()
                    ForEach(model.watched, id: \.self) { ref in
                        HStack {
                            Text(ref).font(.caption)
                            Spacer()
                            Button { model.removeWatched(ref) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("paste PR URL", text: $draft.newPR)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.addWatched(draft.newPR); draft.newPR = "" }
                        Button("Watch") { model.addWatched(draft.newPR); draft.newPR = "" }
                    }
                    Toggle("Show merged today", isOn: $model.showMerged)
                        .onChange(of: model.showMerged) { model.save() }
                    Toggle("Show reviews requested", isOn: $model.showReviews)
                        .onChange(of: model.showReviews) { model.save() }
                }
                .padding(.top, 6)
            }
            .font(.caption)

            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 340)
    }
}

@main
struct PRQueueApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Text(model.label)
        }
        .menuBarExtraStyle(.window)
    }
}
