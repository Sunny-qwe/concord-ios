#!/usr/bin/env python3
"""Execute the production Swift wire-encoding methods with a recording transport.
Requires Python 3 and Apple's Swift/Foundation (run on macOS CI).
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text()

def block(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

client = read('ConcordiOS/Models/ConcordClient.swift')
app = read('ConcordiOS/Models/AppCore.swift')
tunnel = read('PacketTunnel/PacketTunnelProvider.swift')
proxy = read('ConcordiOS/Models/ProxyStore.swift')
# These methods must continue to use error-propagating writes before readback.
diagnostic = block(proxy, 'private func unifiedDelayDiagnosticLine(')
assert 'try await AppCore.shared.setUnifiedDelay(enabled)' in diagnostic
assert 'try await client.setUnifiedDelay(enabled)' in diagnostic
assert 'guard let actual = general.unifiedDelay' in diagnostic
assert 'actual == enabled' in diagnostic
assert 'encoder.keyEncodingStrategy = .convertToSnakeCase' in client

conversion_start = tunnel.index('                var patch = general')
conversion_end = tunnel.index('                _ = try await sendCoreRequest(method: "config.patch", params: patch', conversion_start)
conversion = tunnel[conversion_start:conversion_end]
swift = '''import Foundation
struct EmptyResult: Codable {}
struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
'''
swift += block(client, 'struct ConcordConfigPatchParams: Encodable')
swift += '''
final class Client {
    static let requestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    var captured: [String: Any] = [:]
    func callRaw<Result: Decodable>(method: String, paramsData: Data, resultType: Result.Type) async throws -> Result {
        precondition(method == "config.patch")
        captured = try JSONSerialization.jsonObject(with: paramsData) as! [String: Any]
        return EmptyResult() as! Result
    }
'''
swift += block(client, 'func configPatch(_ params: ConcordConfigPatchParams)')
swift += block(client, 'func setUnifiedDelay(_ enabled: Bool)') + '\n}\n'
swift += '''final class App {
    var captured: [String: Any] = [:]
    func sendRequest<Result: Decodable>(method: String, params: [String: Any], resultType: Result.Type) async throws -> Result {
        precondition(method == "config.patch")
        captured = params
        return EmptyResult() as! Result
    }
'''
swift += block(app, 'func setUnifiedDelay(_ enabled: Bool)') + '\n}\n'
swift += '''func convert(_ general: [String: Any], _ overrides: [String: Any]?) -> [String: Any] {
    func effectiveTopLevelOverrides(section: String) -> [String: Any]? { overrides }
'''
swift += conversion + '\n return patch\n}\n'
swift += '''
@main struct Tests {
    static func main() async throws {
        let client = Client()
        let app = App()
        for enabled in [true, false] {
            try await client.setUnifiedDelay(enabled)
            precondition(client.captured.count == 1)
            precondition(client.captured["unifiedDelay"] as? Bool == enabled)
            try await app.setUnifiedDelay(enabled)
            precondition(app.captured["unifiedDelay"] as? Bool == enabled)
            let params = ConcordConfigPatchParams(unifiedDelay: enabled)
            try await client.configPatch(params)
            precondition(client.captured.count == 1)
            precondition(client.captured["unified_delay"] == nil)
            precondition(client.captured["unifiedDelay"] as? Bool == enabled)
            let old = convert(["unified_delay": enabled, "mode": "rule"], nil)
            precondition(old["unifiedDelay"] as? Bool == enabled)
            precondition(old["unified_delay"] == nil)
            precondition(old["mode"] as? String == "rule")
            let overridden = convert(["unified_delay": !enabled], ["unified-delay": enabled])
            precondition(overridden["unifiedDelay"] as? Bool == enabled)
        }
        try await client.configPatch(ConcordConfigPatchParams(mode: "direct"))
        precondition(client.captured.count == 1)
        precondition(client.captured["mode"] as? String == "direct")
        precondition(convert(["unifiedDelay": false], nil)["unifiedDelay"] as? Bool == false)
        precondition(convert(["mode": "rule"], nil)["unifiedDelay"] == nil)
        let mixed = convert(["unified_delay": true, "unifiedDelay": false], nil)
        precondition(mixed["unifiedDelay"] as? Bool == false)
        precondition(mixed["unified_delay"] == nil)
        let overrideMixed = convert(["unified_delay": true, "unifiedDelay": true], ["unified-delay": false])
        precondition(overrideMixed["unifiedDelay"] as? Bool == false)
        try await client.configPatch(ConcordConfigPatchParams(logLevel: "info", tcpConcurrent: false, unifiedDelay: false))
        precondition(client.captured["log_level"] as? String == "info")
        precondition(client.captured["tcp_concurrent"] as? Bool == false)
        precondition(client.captured["unifiedDelay"] as? Bool == false)
        print("PASS: App/tunnel encoding ON/OFF, nil omission, mode-only patch, legacy startup conversion, overlay precedence and diagnostic guards")
    }
}
'''
with tempfile.TemporaryDirectory() as temp:
    source = pathlib.Path(temp) / 'UnifiedDelay.swift'
    source.write_text(swift)
    binary = pathlib.Path(temp) / 'test'
    subprocess.run(['swiftc', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
