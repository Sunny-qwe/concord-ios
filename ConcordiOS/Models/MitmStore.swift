import Foundation
import Combine

// MARK: - MITM capture store (FlClash: MITM requests page)
// Backed by Concord mitm.runScript / mitm.exchanges / mitm.exchange /
// mitm.body (upstream crates/mitm/src/capture.rs). The exchange list
// is per connection: mitm.exchanges takes a connection id from
// connection.watch and returns {capturing, since, exchanges: [...]}.
// A script run takes a script name (there is no list-scripts API) and
// returns open JSON.
//
// In `.sample` mode the client answers from the built-in sample
// exchanges; the view labels them as sample data, as everywhere else.

final class MitmStore: ObservableObject {
    @Published var scriptName = ""
    @Published var scriptResult: JSONValue?
    @Published var scriptMessage: String?
    @Published var isRunningScript = false

    @Published var connectionId: UInt64?
    @Published var capturing = false
    @Published var exchanges: [MitmExchangeSummary] = []
    @Published var isLoadingExchanges = false
    @Published var exchangesMessage: String?

    @Published var selectedExchange: MitmExchangeSummary?
    @Published var exchangeDetail: JSONValue?
    /// The same detail, typed (mitm.exchange returns the full
    /// exchange: headers, original URL, protocol, TTFB, matched
    /// actions). Nil when the open JSON does not decode as one —
    /// the raw JSON section still shows.
    @Published var exchangeDetailTyped: MitmExchangeDetail?
    @Published var exchangeBody: MitmBody?
    @Published var isLoadingDetail = false
    @Published var detailMessage: String?

    /// The `since` the last mitm.exchanges answer carried (capture
    /// start, RFC 3339), and whether requests from before it are
    /// missing from the list (upstream `missing`: the connection
    /// started before capture did).
    @Published var exchangesSince: String?
    @Published var exchangesMissingNotice = false

    // MARK: - Cross-connection query (mitm.query, upstream 0c9788f)
    // The capture across connections, newest first: a text search
    // over URL / method / content type / error / app, with paging
    // through the answer's `next` cursor. Unlike mitm.exchanges
    // (per connection), this needs no connection id.

    /// The search text the user typed (matched without case in the
    /// URL, method, content type, error or app).
    @Published var queryText = ""
    /// The current page's exchanges, newest first; paging appends.
    @Published var queryResults: [MitmExchangeSummary] = []
    /// How many held exchanges match the filter (all pages, not
    /// just the ones loaded).
    @Published var queryMatched: UInt64?
    /// How many exchanges the core still holds in total.
    @Published var queryHeld: UInt64?
    /// The `before` of the next page; nil when this page holds the
    /// last match.
    @Published var queryNext: Int64?
    @Published var isQuerying = false
    @Published var queryMessage: String?
    @Published var hasQueried = false

    /// Whether the privacy warning before copy/export was accepted
    /// once (upstream `mitmExportWarnedProvider`).
    var exportWarned: Bool {
        get { UserDefaults.standard.bool(forKey: "ConcordiOS.mitm.exportWarned") }
        set { UserDefaults.standard.set(newValue, forKey: "ConcordiOS.mitm.exportWarned") }
    }

    let client: ConcordClient

    init(client: ConcordClient = ConcordClient()) {
        self.client = client
    }

    /// Runs one named MITM script (mitm.runScript) and keeps its open
    /// JSON result for display.
    @MainActor
    func runScript() async {
        let name = scriptName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            scriptMessage = "请输入脚本名"
            return
        }
        isRunningScript = true
        defer { isRunningScript = false }
        do {
            scriptResult = try await client.mitmRunScript(name: name).result
            scriptMessage = "脚本 \(name) 已运行"
        } catch {
            scriptResult = nil
            scriptMessage = "运行失败：\(error.localizedDescription)"
        }
    }

    /// Runs a cross-connection capture query (mitm.query). An empty
    /// search text matches everything. `loadMore: true` pages with
    /// the last answer's `next` cursor and appends; otherwise the
    /// first page replaces the results.
    @MainActor
    func runQuery(loadMore: Bool = false) async {
        if loadMore {
            guard let next = queryNext else { return }
            await runQueryPage(before: next, append: true)
            return
        }
        await runQueryPage(before: nil, append: false)
    }

    @MainActor
    private func runQueryPage(before: Int64?, append: Bool) async {
        isQuerying = true
        defer { isQuerying = false }
        do {
            var filter = ConcordMitmFilter()
            let text = queryText.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { filter.text = text }
            let answer = try await client.mitmQuery(filter: filter, before: before)
            hasQueried = true
            queryMatched = answer.matched
            queryHeld = answer.held
            queryNext = answer.next
            if append {
                var seen = Set(queryResults.map(\.exchangeId))
                for exchange in answer.exchanges where !seen.contains(exchange.exchangeId) {
                    seen.insert(exchange.exchangeId)
                    queryResults.append(exchange)
                }
            } else {
                queryResults = answer.exchanges
            }
            if queryResults.isEmpty {
                queryMessage = answer.capturing ? "没有匹配的拦截记录" : "MITM 捕获未开启（config.apply 的 options.mitmCapture）"
            } else {
                queryMessage = nil
            }
        } catch {
            if !append { queryResults = [] }
            queryMessage = "查询失败：\(error.localizedDescription)"
        }
    }

    /// Loads the captured exchanges of one connection (mitm.exchanges).
    @MainActor
    func loadExchanges(connection: UInt64) async {
        connectionId = connection
        isLoadingExchanges = true
        defer { isLoadingExchanges = false }
        do {
            let result = try await client.mitmExchanges(connection: connection).result
            let list = try result.decoded(as: MitmExchangeList.self)
            capturing = list.capturing
            exchanges = list.exchanges
            exchangesSince = list.since
            exchangesMessage = list.exchanges.isEmpty
                ? (list.capturing ? "正在捕获，暂无拦截记录" : "MITM 捕获未开启（config.apply 的 options.mitmCapture）")
                : nil
            // Upstream `missing`: the connection began before
            // capture started, so requests from before `since` are
            // not in this list. The connection's start is unix
            // millis (ConnectionStore C1); `since` is RFC 3339.
            exchangesMissingNotice = false
            if let since = list.since,
               let sinceDate = ISO8601DateFormatter().date(from: since),
               let snapshot = try? await client.connectionSnapshot(),
               let conn = snapshot.connections.first(where: { $0.connectionId == connection }) {
                exchangesMissingNotice = Date(timeIntervalSince1970: TimeInterval(conn.start) / 1000) < sinceDate
            }
        } catch {
            exchanges = []
            exchangesMessage = "读取拦截记录失败：\(error.localizedDescription)"
        }
    }

    /// Loads one exchange's full detail (mitm.exchange) as open JSON.
    @MainActor
    func loadExchangeDetail(_ summary: MitmExchangeSummary) async {
        selectedExchange = summary
        exchangeDetail = nil
        exchangeDetailTyped = nil
        exchangeBody = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            exchangeDetail = try await client.mitmExchange(id: summary.exchangeId).result
            exchangeDetailTyped = try? exchangeDetail?.decoded(as: MitmExchangeDetail.self)
            detailMessage = nil
        } catch {
            detailMessage = "读取详情失败：\(error.localizedDescription)"
        }
    }

    /// Loads a request or response body (mitm.body). The core stores
    /// the body base64-encoded; `response: true` fetches the response
    /// body instead of the request body.
    @MainActor
    func loadBody(id: Int64, response: Bool) async {
        do {
            exchangeBody = try await client.mitmBody(id: id, response: response).result.decoded(as: MitmBody.self)
            detailMessage = nil
        } catch {
            detailMessage = "读取正文失败：\(error.localizedDescription)"
        }
    }

    /// Reads a body without touching the detail's displayed one —
    /// the copy/export menu fetches bodies on demand (upstream
    /// `withExchange` + `_body`).
    func loadBodyData(id: Int64, response: Bool) async -> MitmBody? {
        try? await client.mitmBody(id: id, response: response).result.decoded(as: MitmBody.self)
    }
}

// MARK: - Full exchange (mitm.exchange)
//
// The wire keys are kebab-case, as in MitmExchangeSummary
// (upstream crates/mitm/src/capture.rs, models/core.dart
// MitmExchange): headers are name → values, actions are the
// rewrites / scripts / map-local that acted on this exchange.

struct MitmExchangeAction: Codable {
    let kind: String
    let phase: String?
    let detail: String?
    /// The module whose line acted; nil/empty for the profile's
    /// own (upstream 9d1f485; the wire has carried this since
    /// 0c9788f, the app only decodes it now).
    var module: String? = nil

    static func kindLabel(for kind: String) -> String {
        switch kind {
        case "url-rewrite": return "URL 重写"
        case "header-rewrite": return "头重写"
        case "body-rewrite": return "正文重写"
        case "map-local": return "本地映射"
        case "script": return "脚本"
        default: return kind
        }
    }

    var kindLabel: String { Self.kindLabel(for: kind) }

    var phaseLabel: String? {
        switch phase {
        case "request": return "请求"
        case "response": return "响应"
        default: return phase
        }
    }
}

struct MitmExchangeDetail: Codable {
    let exchangeId: Int64
    let start: String
    let pending: Bool?
    let duration: Int64
    let ttfb: Int64?
    let method: String
    let url: String
    let originalUrl: String?
    let proto: String?
    let status: Int32
    /// The response's reason phrase as the client got it
    /// (upstream 9d1f485, b678d79): the standard one for its
    /// status, e.g. "OK". Omitted when there is none.
    var reason: String? = nil
    let requestSize: Int64
    let responseSize: Int64
    let error: String?
    let connection: String?
    let requestHeader: [String: [String]]?
    let responseHeader: [String: [String]]?
    let actions: [MitmExchangeAction]?

    enum CodingKeys: String, CodingKey {
        case exchangeId = "id"
        case start, pending, duration, ttfb, method, url, status, error, connection, actions
        case originalUrl = "original-url"
        case proto
        case reason
        case requestSize = "request-size"
        case responseSize = "response-size"
        case requestHeader = "request-header"
        case responseHeader = "response-header"
    }

    /// A header's values, case-insensitive on the name.
    func headerValue(_ name: String, response: Bool) -> String {
        let headers = response ? responseHeader : requestHeader
        for (key, values) in headers ?? [:] where key.lowercased() == name.lowercased() {
            return values.first ?? ""
        }
        return ""
    }

    /// Headers sorted by name, each with all its values (upstream
    /// _MitmSideView sorts the names).
    func sortedHeaders(response: Bool) -> [(String, [String])] {
        let headers = response ? responseHeader : requestHeader
        return (headers ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
}
