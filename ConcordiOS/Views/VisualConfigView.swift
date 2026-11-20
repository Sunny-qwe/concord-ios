import SwiftUI

// MARK: - Visual config (FlClash: lib/views/profiles/visual.dart)
// Visual editor hub for the active profile: node sources, a new
// custom subscription, and the local proxies. Edits write back
// through the existing profile apply path (the custom subscription
// editor and the proxies page both bake into the active profile's
// YAML and re-apply it — see CustomSubscriptionEditorView and
// CustomProxiesView).

struct VisualConfigView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var customStore = CustomSubscriptionStore()
    @State private var createdSubscriptionID: UUID?
    @State private var showCreatedEditor = false
    /// Offline node count for the "当前配置" section, loaded off
    /// the main thread (see the .task below). It used to call
    /// localNodeNames — a whole-YAML scan — inline in body, on
    /// every body evaluation, stalling the first frame.
    @State private var localNodeCount: Int?

    private var active: Profile? { profileStore.activeProfile }

    var body: some View {
        List {
            if let active {
                Section("当前配置") {
                    LabeledContent("订阅", value: active.name)
                    if let inspect = profileStore.inspect {
                        LabeledContent("节点", value: "\(inspect.proxies)")
                        LabeledContent("代理组", value: "\(inspect.proxyGroups)")
                        LabeledContent("规则", value: "\(inspect.rules)")
                    } else {
                        LabeledContent("节点", value: localNodeCount.map { "\($0)（本地文件）" } ?? "…")
                    }
                }
            } else {
                Section {
                    Text("还没有激活的订阅：先在订阅页导入并切换一个，再回来做可视化配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    NodeSourcesView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("节点来源").font(.system(size: 13, weight: .semibold))
                        Text("看每个节点来自哪个订阅")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    let created = customStore.create(name: "未命名自定义订阅")
                    createdSubscriptionID = created.id
                    showCreatedEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("添加自定义配置").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("新建一套分组 / 提供方 / 规则，可视化编辑")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    CustomProxiesView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("代理").font(.system(size: 13, weight: .semibold))
                        Text("本地节点：加入哪个分组、改节点参数")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    CustomSubscriptionListView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自定义订阅").font(.system(size: 13, weight: .semibold))
                        Text("已建的自定义订阅（\(customStore.subscriptions.count) 个），点开编辑分组、拨号器、提供方和规则")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("可视化配置")
            } footer: {
                Text("可视化编辑的是「自定义订阅」里的数据；点「应用到当前配置」才会写进当前订阅的 YAML 并生效。")
                    .font(.system(size: 13))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .navigationTitle("可视化配置")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: active?.id) {
            // Only needed while the core's inspect snapshot has not
            // arrived (the branch above); the scan runs off-thread
            // and the count fills in when it lands.
            localNodeCount = nil
            guard let active, profileStore.inspect == nil else { return }
            let storeRef = profileStore
            localNodeCount = await Task.detached(priority: .userInitiated) {
                storeRef.localNodeNames(for: active).count
            }.value
        }
        .navigationDestination(isPresented: $showCreatedEditor) {
            if let createdSubscriptionID {
                CustomSubscriptionEditorView(subscriptionID: createdSubscriptionID)
            }
        }
    }
}
