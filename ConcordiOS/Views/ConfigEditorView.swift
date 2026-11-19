import SwiftUI

// MARK: - Config editor (Profiles -> 编辑配置)
// A full-screen YAML editor for the ACTIVE profile — the mobile
// equivalent of FlClash's desktop config editor. Loads the profile's
// YAML from the App Group container, edits it as monospace text,
// and saves it back.
//
// Save flow, in order:
//   1. Local sanity check (non-empty UTF-8, looks like a Clash /
//      mihomo document) — always.
//   2. Core validation (config.validate) when the core is reachable
//      (live mode + VPN running): the text is written to a temporary
//      file in the App Group (the core reads it with a plain fs::read
//      in the extension process) and validated there. Any issue aborts
//      the save before the active config is touched.
//   3. When the VPN is stopped the core is unreachable: the page says
//      so, saves after the local check only, and the extension
//      validates again at the next VPN start.
//   4. A confirmation alert before the file is actually overwritten.
// Unsaved changes: the page keeps a draft in tmp (restored with a
// prompt if you leave and come back), and 放弃修改 asks first.

struct ConfigEditorView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var client: ConcordClient
    @EnvironmentObject private var tunnelManager: TunnelManager

    @State private var text = ""
    @State private var originalText = ""
    @State private var isLoaded = false
    @State private var loadError: String?
    @State private var validationIssues: [ConcordIssue] = []
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showSaveConfirm = false
    @State private var showDiscardConfirm = false
    @State private var showDraftAlert = false
    @State private var pendingSaveNote = ""
    /// YAML editing state: the caret (for key completion) and the
    /// controller the completion row uses to insert at the caret.
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @StateObject private var yamlController = YamlEditorController()

    private var isDirty: Bool { isLoaded && text != originalText }

    private static var draftURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("concord-editor-draft.yaml")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                ContentUnavailableView("打不开配置", systemImage: "doc.text.magnifyingglass", description: Text(loadError))
            } else if !isLoaded {
                ProgressView("正在读取配置…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorHeader
                YamlEditorView(text: $text, selectedRange: $selectedRange, controller: yamlController)
                    .onChange(of: text) { _, _ in saveDraft() }
                if !completionSuggestions.isEmpty {
                    completionRow
                }
                statusArea
            }
        }
        .navigationTitle("编辑配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await validateBeforeSave() } }
                    .disabled(!isDirty || isWorking)
            }
            ToolbarItem(placement: .topBarLeading) {
                if isDirty {
                    Button("放弃修改") { showDiscardConfirm = true }
                        .disabled(isWorking)
                }
            }
        }
        .task { load() }
        .alert("保存并应用吗？", isPresented: $showSaveConfirm) {
            Button("保存") { Task { await save() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text(pendingSaveNote)
        }
        .alert("放弃未保存的修改？", isPresented: $showDiscardConfirm) {
            Button("放弃", role: .destructive) {
                text = originalText
                validationIssues = []
                message = nil
                errorMessage = nil
                try? FileManager.default.removeItem(at: Self.draftURL)
            }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("编辑器里的改动会被丢弃，恢复为磁盘上的版本。")
        }
        .alert("恢复上次未保存的修改吗？", isPresented: $showDraftAlert) {
            Button("恢复草稿") {
                if let draft = try? String(contentsOf: Self.draftURL, encoding: .utf8) {
                    text = draft
                    message = "已恢复上次未保存的草稿。"
                }
            }
            Button("丢弃草稿", role: .destructive) {
                try? FileManager.default.removeItem(at: Self.draftURL)
            }
        } message: {
            Text("上次离开编辑器时还有未保存的修改。")
        }
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profileStore.activeProfile?.name ?? "当前配置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if isDirty {
                    PillBadge(text: "未保存", tint: .orange)
                } else {
                    PillBadge(text: "已保存", tint: .green)
                }
            }
            Text(client.mode == .live
                 ? (tunnelManager.isRunning
                    ? "保存前会先用核心校验（config.validate），有问题就不会覆盖。"
                    : "VPN 未运行：保存前只能做本地检查，核心会在下次启动 VPN 时再校验一次。")
                 : "示例模式：保存只做本地检查，不会发给核心。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(ConcordTheme.cardBackground)
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isWorking {
                ProgressView("正在校验…")
            }
            if !validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("校验发现 \(validationIssues.count) 个问题，未保存：")
                        .font(.system(size: 13))
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    ForEach(Array(validationIssues.enumerated()), id: \.offset) { _, issue in
                        Text("· \(issue.message)")
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ConcordTheme.cardBackground)
    }

    // MARK: - Key completion (FlClash clash_completion.dart,
    // top-level keys only — a full schema engine is out of scope)

    /// The word the caret is typing, if the caret sits at a
    /// top-level key position: an empty (or word-only) line at
    /// indent 0 with no ':' before the caret.
    private var currentKeyPrefix: (word: String, range: NSRange)? {
        let nsText = text as NSString
        guard selectedRange.location <= nsText.length else { return nil }
        let lineRange = nsText.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let line = nsText.substring(with: lineRange)
        let caretInLine = selectedRange.location - lineRange.location
        let beforeCaret = String(line.prefix(caretInLine))
        guard !beforeCaret.contains(":") else { return nil }
        guard beforeCaret.prefix(while: { $0 == " " }).isEmpty else { return nil }
        var word = beforeCaret
        if word.hasPrefix("- ") { word = String(word.dropFirst(2)) }
        guard word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }
        let wordStart = lineRange.location + (beforeCaret.count - word.count)
        return (word, NSRange(location: wordStart, length: word.count))
    }

    private var completionSuggestions: [String] {
        guard let (word, _) = currentKeyPrefix else { return [] }
        let matches = YamlClashKeys.topLevel.filter {
            $0.hasPrefix(word) && $0 != word
        }
        return Array(matches.prefix(12))
    }

    /// Suggestion row above the keyboard: tapping a key inserts
    /// it plus ": " at the caret, replacing the typed prefix.
    private var completionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(completionSuggestions, id: \.self) { key in
                    Button(key) {
                        guard let (_, range) = currentKeyPrefix else { return }
                        yamlController.insert("\(key): ", replacing: range)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(.body, design: .monospaced))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(ConcordTheme.cardBackground)
    }

    private func load() {
        guard let yaml = profileStore.activeProfileYAML() else {
            loadError = "没有已激活的订阅，或者它的配置文件找不到了"
            return
        }
        originalText = yaml
        text = yaml
        isLoaded = true
        // A draft from a previous interrupted edit session wins a
        // prompt — it is never silently applied or discarded.
        if let draft = try? String(contentsOf: Self.draftURL, encoding: .utf8),
           draft != yaml {
            showDraftAlert = true
        }
    }

    private func saveDraft() {
        guard isLoaded else { return }
        try? text.write(to: Self.draftURL, atomically: true, encoding: .utf8)
    }

    private func validateBeforeSave() async {
        validationIssues = []
        message = nil
        errorMessage = nil
        // 1. Local sanity check, always.
        if let problem = ProfileStore.localSanityCheckText(text) {
            errorMessage = "本地检查未通过：\(problem)"
            return
        }
        // 2. Core validation when the core is reachable.
        if client.mode == .live, tunnelManager.isRunning {
            isWorking = true
            defer { isWorking = false }
            do {
                let issues = try await profileStore.validateYAMLText(text)
                if !issues.isEmpty {
                    validationIssues = issues
                    return
                }
                pendingSaveNote = "核心校验通过。保存后会立即重新应用到核心（VPN 正在运行）。"
            } catch {
                errorMessage = "核心校验失败：\(error.localizedDescription)。未保存——请稍后重试，或先停止 VPN 再用本地检查保存。"
                return
            }
        } else if client.mode == .live {
            pendingSaveNote = "VPN 未运行：只做了本地检查。保存后下次启动 VPN 时核心会再校验一次，校验失败时隧道会启动失败并报错。"
        } else {
            pendingSaveNote = "示例模式：只做了本地检查，不会发给核心。"
        }
        showSaveConfirm = true
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        let result = await profileStore.saveActiveProfileYAML(text)
        message = result
        errorMessage = nil
        originalText = text
        try? FileManager.default.removeItem(at: Self.draftURL)
    }
}

// MARK: - YAML highlighting + key completion
//
// TextEditor cannot colour text, so the editor is a UITextView
// (UIViewRepresentable) whose attributedText is re-built from the
// plain text on every edit, with the caret restored afterwards.
// Highlighting is line-based and deliberately small: keys, list
// dashes, comments, quoted strings and scalars. '#' inside a
// quoted string is treated as a comment start — a known
// simplification. A full schema engine (FlClash
// clash_completion.dart / clash_schema.dart) is out of scope:
// completion only offers the common top-level Clash keys when the
// caret is at a top-level key position.

/// Common top-level Clash / mihomo config keys (FlClash
/// clash_schema.dart `clashConfigSchema`).
enum YamlClashKeys {
    static let topLevel: [String] = [
        "mixed-port", "port", "socks-port", "redir-port", "tproxy-port",
        "allow-lan", "bind-address", "lan-allowed-ips", "lan-disallowed-ips",
        "authentication", "mode", "log-level", "ipv6", "unified-delay",
        "tcp-concurrent", "find-process-mode", "global-ua",
        "keep-alive-interval", "keep-alive-idle", "disable-keep-alive",
        "interface-name", "routing-mark", "external-controller",
        "external-controller-cors", "secret", "external-ui",
        "external-ui-name", "external-ui-url", "external-doh-server",
        "profile", "geodata-mode", "geodata-loader", "geosite-matcher",
        "geo-auto-update", "geo-update-interval", "geox-url", "hosts",
        "tls", "experimental", "dns", "tun", "sniffer", "ntp",
        "listeners", "tunnels", "proxies", "proxy-groups",
        "proxy-providers", "rule-providers", "rules", "script",
    ]
}

enum YamlHighlighter {
    static func highlighted(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        result.addAttribute(.font, value: font, range: full)
        result.addAttribute(.foregroundColor, value: UIColor.label, range: full)
        guard nsText.length > 0 else { return result }

        let keyPattern = try? NSRegularExpression(pattern: #"^(\s*)(- )?([\w.\-]+)(:)"#, options: [])
        let scalarPattern = try? NSRegularExpression(pattern: #":\s*(true|false|null|~|-?\d[\w.:-]*)\s*$"#, options: [])
        let quotedPattern = try? NSRegularExpression(pattern: #"(['\"]).*?\1"#, options: [])

        nsText.enumerateSubstrings(in: full, options: [.byLines]) { _, lineRange, _, _ in
            let line = nsText.substring(with: lineRange)
            // Comment: '#' at line start, or ' #' after content.
            let commentStart: Int?
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                commentStart = line.firstIndex(of: "#").map { line.distance(from: line.startIndex, to: $0) }
            } else if let hashRange = line.range(of: " #") {
                commentStart = line.distance(from: line.startIndex, to: hashRange.lowerBound) + 1
            } else {
                commentStart = nil
            }
            let codeEnd = commentStart ?? line.count
            if let start = commentStart {
                let range = NSRange(location: lineRange.location + start, length: lineRange.length - start)
                if range.length > 0 {
                    result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                }
            }
            guard codeEnd > 0 else { return }
            let codeRange = NSRange(location: lineRange.location, length: min(codeEnd, lineRange.length))
            let code = nsText.substring(with: codeRange)
            // Key + list dash.
            if let match = keyPattern?.firstMatch(in: code, options: [], range: NSRange(location: 0, length: (code as NSString).length)) {
                let keyRange = match.range(at: 3)
                if keyRange.location != NSNotFound {
                    let shifted = NSRange(location: codeRange.location + keyRange.location, length: keyRange.length)
                    result.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: shifted)
                }
                let dashRange = match.range(at: 2)
                if dashRange.location != NSNotFound {
                    let shifted = NSRange(location: codeRange.location + dashRange.location, length: dashRange.length)
                    result.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: shifted)
                }
            }
            // Quoted strings.
            quotedPattern?.enumerateMatches(in: code, options: [], range: NSRange(location: 0, length: (code as NSString).length)) { match, _, _ in
                guard let match else { return }
                let shifted = NSRange(location: codeRange.location + match.range.location, length: match.range.length)
                result.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: shifted)
            }
            // Bare scalars (true/false/null/numbers) after a colon.
            if let match = scalarPattern?.firstMatch(in: code, options: [], range: NSRange(location: 0, length: (code as NSString).length)) {
                let valueRange = match.range(at: 1)
                if valueRange.location != NSNotFound {
                    let shifted = NSRange(location: codeRange.location + valueRange.location, length: valueRange.length)
                    result.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: shifted)
                }
            }
        }
        return result
    }
}

/// Lets the SwiftUI completion row insert text at the UITextView's
/// caret; the coordinator wires the handler in makeUIView.
final class YamlEditorController: ObservableObject {
    var insertHandler: ((NSRange, String) -> Void)?

    func insert(_ text: String, replacing range: NSRange) {
        insertHandler?(range, text)
    }
}

/// Monospace UITextView with YAML highlighting. The plain text is
/// the source of truth (bound to ConfigEditorView); the attributed
/// form is derived and never written back.
struct YamlEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var controller: YamlEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.backgroundColor = .secondarySystemBackground
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.delegate = context.coordinator
        textView.attributedText = YamlHighlighter.highlighted(text)
        context.coordinator.lastAppliedText = text
        controller.insertHandler = { [weak textView] range, replacement in
            guard let textView else { return }
            context.coordinator.replace(range: range, with: replacement, in: textView)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // External change (load / discard / draft restore): the
        // binding moved without a user edit, so re-highlight.
        if context.coordinator.lastAppliedText != text {
            let caret = textView.selectedRange
            textView.attributedText = YamlHighlighter.highlighted(text)
            textView.selectedRange = caret
            context.coordinator.lastAppliedText = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: YamlEditorView
        var lastAppliedText = ""
        private var isApplying = false

        init(_ parent: YamlEditorView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying else { return }
            let plain = textView.text ?? ""
            lastAppliedText = plain
            parent.text = plain
            parent.selectedRange = textView.selectedRange
            // Do not re-highlight while an IME is composing (pinyin
            // etc.): replacing the attributed text would drop the
            // marked text. The next committed edit re-highlights.
            guard textView.markedTextRange == nil else { return }
            rehighlight(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }

        private func rehighlight(_ textView: UITextView) {
            let caret = textView.selectedRange
            isApplying = true
            textView.attributedText = YamlHighlighter.highlighted(textView.text ?? "")
            textView.selectedRange = caret
            isApplying = false
        }

        func replace(range: NSRange, with replacement: String, in textView: UITextView) {
            let current = textView.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return }
            var newText = current
            newText.replaceSubrange(swiftRange, with: replacement)
            isApplying = true
            parent.text = newText
            lastAppliedText = newText
            textView.attributedText = YamlHighlighter.highlighted(newText)
            let newCaret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            textView.selectedRange = newCaret
            parent.selectedRange = newCaret
            isApplying = false
        }
    }
}
