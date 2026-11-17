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
    @Published var exchangeBody: MitmBody?
    @Published var isLoadingDetail = false
    @Published var detailMessage: String?

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
            exchangesMessage = list.exchanges.isEmpty
                ? (list.capturing ? "正在捕获，暂无拦截记录" : "MITM 捕获未开启（config.apply 的 options.mitmCapture）")
                : nil
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
        exchangeBody = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            exchangeDetail = try await client.mitmExchange(id: summary.exchangeId).result
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
}
