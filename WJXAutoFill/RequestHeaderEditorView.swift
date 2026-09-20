import SwiftUI

struct RequestHeaderProfilesView: View {
    @ObservedObject var store: RuleStore
    @State private var editingProfile: RequestHeaderProfile?
    @State private var pendingDeleteProfile: RequestHeaderProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("请求头配置")
                        .font(.headline)
                    Text("已启用 \(enabledCount) / \(store.requestHeaderProfiles.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editingProfile = .newProfile
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .tint(AppTheme.brand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            if store.requestHeaderProfiles.isEmpty {
                VStack(spacing: 14) {
                    GlassEffectContainer(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(AppTheme.brandGradient)
                            .frame(width: 74, height: 74)
                            .floatingGlass(radius: 24)
                    }
                    Text("暂无请求头配置")
                        .font(.headline)
                    Text("新增配置后，可按网址为问卷主请求和页面内 fetch/XHR 设置请求头。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("创建第一个配置") {
                        editingProfile = .newProfile
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(store.requestHeaderProfiles) { profile in
                            profileRow(profile)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDeleteProfile = profile
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        store.cloneRequestHeaderProfile(profile.id)
                                    } label: {
                                        Label("克隆", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)
                                }
                        }
                    } footer: {
                        Text("配置值安全保存在 Keychain。修改后请刷新页面；iOS 无法改写图片、脚本、WebSocket 等所有子资源请求头。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .sheet(item: $editingProfile) { profile in
            RequestHeaderProfileEditorView(profile: profile) { savedProfile in
                store.upsertRequestHeaderProfile(savedProfile)
                editingProfile = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "删除请求头配置？",
            isPresented: Binding(
                get: { pendingDeleteProfile != nil },
                set: { if !$0 { pendingDeleteProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profile = pendingDeleteProfile {
                Button("删除“\(profile.name)”", role: .destructive) {
                    store.deleteRequestHeaderProfile(profile.id)
                    pendingDeleteProfile = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingDeleteProfile = nil
            }
        }
    }

    private var enabledCount: Int {
        store.requestHeaderProfiles.filter(\.isEnabled).count
    }

    private func profileRow(_ profile: RequestHeaderProfile) -> some View {
        HStack(spacing: 11) {
            Toggle(
                "启用 \(profile.name)",
                isOn: Binding(
                    get: { profile.isEnabled },
                    set: {
                        store.setRequestHeaderProfileEnabled(profile.id, enabled: $0)
                    }
                )
            )
            .labelsHidden()

            Button {
                editingProfile = profile
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(profile.urlPattern)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text("\(profile.headers.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(profile.isEnabled ? Color.blue : Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .opacity(profile.isEnabled ? 1 : 0.62)
    }
}

private struct RequestHeaderProfileEditorView: View {
    @State private var draft: RequestHeaderProfile
    let onSave: (RequestHeaderProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        profile: RequestHeaderProfile,
        onSave: @escaping (RequestHeaderProfile) -> Void
    ) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("配置") {
                    TextField("配置名称", text: $draft.name)
                    TextField("网址规则，例如 *.wjx.cn", text: $draft.urlPattern)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("启用配置", isOn: $draft.isEnabled)
                }

                Section {
                    ForEach($draft.headers) { $header in
                        headerEditor($header)
                    }

                    Button {
                        draft.headers.append(RequestHeaderMutation())
                    } label: {
                        Label("添加请求头", systemImage: "plus.circle")
                    }
                } header: {
                    Text("请求头规则")
                } footer: {
                    Text("多个启用配置同时匹配时，列表中靠后的配置覆盖靠前配置的同名请求头。")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Text("支持域名（wjx.cn）、通配符（*.wjx.cn）和完整网址。主页面请求由原生 URLRequest 修改，页面内 fetch/XHR 由脚本注入修改；受 iOS 安全限制，部分系统请求头不可修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(draft.name.isEmpty ? "请求头配置" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(validationMessage != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func headerEditor(_ header: Binding<RequestHeaderMutation>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("操作", selection: header.action) {
                ForEach(RequestHeaderAction.allCases) { action in
                    Label(action.displayName, systemImage: action.symbolName)
                        .tag(action)
                }
            }
            .pickerStyle(.segmented)

            TextField("请求头名称，例如 Authorization", text: header.name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if header.wrappedValue.action != .delete {
                if RequestHeaderProfileValidator.isSensitiveHeader(header.wrappedValue.name) {
                    SecureField("请求头值", text: header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    TextField("请求头值", text: header.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Button(role: .destructive) {
                draft.headers.removeAll { $0.id == header.wrappedValue.id }
            } label: {
                Label("删除这条规则", systemImage: "trash")
                    .font(.caption)
            }
        }
        .padding(.vertical, 5)
    }

    private var validationMessage: String? {
        RequestHeaderProfileValidator.validationMessage(for: draft)
    }
}
