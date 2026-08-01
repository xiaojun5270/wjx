import SwiftUI

struct RuleEditorView: View {
    @ObservedObject var store: RuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var expandedPresetIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.wjx.cn/...", text: $store.surveyURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if store.surveyURL == nil {
                        Label("请输入 wjx.cn 的 HTTPS 问卷地址", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    Toggle("页面加载后自动填写", isOn: $store.autoFillOnLoad)
                    Toggle("填写完成后自动提交", isOn: $store.autoSubmitAfterFill)
                } header: {
                    Text("问卷")
                } footer: {
                    Text("自动提交只尝试一次；如果页面要求验证码或提示格式错误，不会循环重复提交。")
                }

                Section {
                    Picker("当前预设", selection: $store.selectedPresetID) {
                        ForEach(store.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                } header: {
                    Text("单次填写")
                } footer: {
                    Text("主页面的“自动填写”使用这里选择的预设；十组并行提交会使用下面全部预设。")
                }

                Section {
                    ForEach(store.presets) { preset in
                        DisclosureGroup(isExpanded: expansionBinding(for: preset.id)) {
                            TextField("姓名", text: answerBinding(presetID: preset.id, keyword: "姓名"))
                                .textContentType(.name)

                            TextField("工号", text: answerBinding(presetID: preset.id, keyword: "工号"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            TextField("邮箱", text: answerBinding(presetID: preset.id, keyword: "邮箱"))
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button(store.selectedPresetID == preset.id ? "当前用于单次填写" : "设为单次填写预设") {
                                store.selectedPresetID = preset.id
                            }
                            .disabled(store.selectedPresetID == preset.id)
                        } label: {
                            HStack {
                                Text(preset.name)
                                Spacer()
                                Image(systemName: preset.isQueueReady ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(preset.isQueueReady ? Color.green : Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("10 组固定提交内容")
                } footer: {
                    Text("每组都必须填写不同的姓名、工号和固定邮箱。页面存在邮箱题时填写该组邮箱；没有邮箱题时自动跳过。")
                }

                Section {
                    LabeledContent("预设数量", value: "10 组")
                    LabeledContent("同时运行", value: "10 个隐藏任务")
                    LabeledContent("已完整填写", value: "\(store.queuePresets.count) / 10")
                    LabeledContent("数据检查", value: store.parallelValidationMessage ?? "可以启动")
                } header: {
                    Text("并行提交")
                } footer: {
                    Text("只有十组姓名、工号、邮箱全部填写后才能启动。执行期间建议保持 App 在前台；验证码或问卷关闭会停止全部任务。")
                }

                Section {
                    Text("并行提交只需在主页面确认启动一次。应用不会绕过验证码、名额或问卷限制。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("预设设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func answerBinding(presetID: UUID, keyword: String) -> Binding<String> {
        Binding(
            get: { store.fixedAnswer(for: keyword, presetID: presetID) },
            set: { store.setFixedAnswer($0, for: keyword, presetID: presetID) }
        )
    }

    private func expansionBinding(for presetID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedPresetIDs.contains(presetID) },
            set: { isExpanded in
                if isExpanded {
                    expandedPresetIDs.insert(presetID)
                } else {
                    expandedPresetIDs.remove(presetID)
                }
            }
        )
    }
}
