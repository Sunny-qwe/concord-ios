import SwiftUI

// MARK: - Visual config (FlClash: lib/views/profiles/visual.dart)
// The same three rows as upstream: node sources, a new custom
// subscription, and the local proxies. Upstream has no "当前配置"
// summary section, so this page has none either.

struct VisualConfigView: View {
    @StateObject private var customStore = CustomSubscriptionStore()
    @State private var createdSubscriptionID: UUID?
    @State private var showCreatedEditor = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    NodeSourcesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(ConcordTheme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("节点来源").font(.footnote.weight(.semibold))
                            Text("看每个节点来自哪个订阅")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Button {
                    let created = customStore.create(name: "未命名自定义订阅")
                    createdSubscriptionID = created.id
                    showCreatedEditor = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.badge.gearshape")
                            .foregroundStyle(ConcordTheme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("添加自定义配置").font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("新建一套分组 / 提供方 / 规则，可视化编辑")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                NavigationLink {
                    CustomProxiesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(ConcordTheme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("代理").font(.footnote.weight(.semibold))
                            Text("本地节点：加入哪个分组、改节点参数")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("可视化配置")
            } footer: {
                Text("可视化编辑的是「自定义订阅」里的数据。")
                    .font(.footnote)
            }
        }
        // v0.2.66: tab-bar clearance for pushed pages
        .contentMargins(.bottom, ConcordTheme.tabBarClearance)
        .font(.footnote.weight(.semibold))
        .navigationTitle("可视化配置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCreatedEditor) {
            if let createdSubscriptionID {
                CustomSubscriptionEditorView(subscriptionID: createdSubscriptionID)
            }
        }
    }
}
