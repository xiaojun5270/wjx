import SwiftUI

struct RuleEditorView: View {
    @ObservedObject var store: RuleStore
    let detectedQuestions: [DetectedQuestion]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("问卷") {
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
                }

                Section {
                    Picker("当前预设", selection: $store.selectedPresetID) {
                        ForEach(store.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }

                    if let index = store.selectedPresetIndex {
                        TextField("预设名称", text: $store.presets[index].name)
                    }

                    HStack {
                        Button("新建空白") {
                            store.addPreset(copyCurrent: false)
                        }
                        Spacer()
                        Button("复制当前") {
                            store.addPreset(copyCurrent: true)
                        }
                        Spacer()
                        Button("删除", role: .destructive) {
                            store.deleteSelectedPreset()
                        }
                        .disabled(store.presets.count <= 1)
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("账号预设")
                } footer: {
                    Text("测试队列会按照这里的排列顺序执行，最多读取前 20 个已填写姓名和工号的预设。复制当前预设后，只需修改不同的姓名和工号。")
                }

                Section {
                    TextField("姓名", text: fixedAnswerBinding(keyword: "姓名"))
                        .textContentType(.name)

                    TextField("工号", text: fixedAnswerBinding(keyword: "工号"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("邮箱域名，例如 example.com", text: randomEmailDomainBinding)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("页面存在邮箱题时，每次生成新的随机邮箱；页面没有邮箱题时自动跳过。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("固定提交内容")
                } footer: {
                    Text("随机邮箱规则始终启用，只在页面检测到邮箱题时填写，不需要手动开关。")
                }

                Section {
                    if let index = store.selectedPresetIndex {
                        ForEach($store.presets[index].rules) { $rule in
                            if isFixedRule(rule.questionContains) {
                                HStack {
                                    Label(rule.questionContains, systemImage: "lock.fill")
                                    Spacer()
                                    Text(rule.questionContains.contains("邮箱") ? "自动随机" : "固定字段")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .deleteDisabled(true)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle("启用", isOn: $rule.isEnabled)
                                    TextField("题目文字关键字", text: $rule.questionContains)
                                    TextField("答案；多选或多个输入框用分号分隔", text: $rule.answer, axis: .vertical)
                                        .lineLimit(1...4)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: store.deleteRules)
                    }

                    Button {
                        store.addRule()
                    } label: {
                        Label("添加规则", systemImage: "plus.circle")
                    }
                } header: {
                    Text("高级填写规则")
                } footer: {
                    Text("上面的固定字段会同步到这里。通常无需修改；如页面题目文字不同，可在这里调整关键字。")
                }

                Section {
                    Stepper(
                        "每次提交后等待 \(Int(store.queueDelaySeconds)) 秒",
                        value: $store.queueDelaySeconds,
                        in: 2...10,
                        step: 1
                    )
                } header: {
                    Text("连续测试")
                } footer: {
                    Text("队列需要在主页面明确确认后启动；验证码、问卷关闭、页面校验失败或网络错误都会停止队列。")
                }

                if !detectedQuestions.isEmpty {
                    Section("页面检测到的题目") {
                        ForEach(detectedQuestions) { question in
                            Button {
                                store.addRule(question: question.text)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(question.text)
                                        .foregroundStyle(.primary)
                                    Text(question.kind)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("单份提交需要逐次确认；连续测试只在主页面确认启动一次。应用不会绕过验证码或问卷限制。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("规则设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func fixedAnswerBinding(keyword: String) -> Binding<String> {
        Binding(
            get: { store.fixedAnswer(for: keyword) },
            set: { store.setFixedAnswer($0, for: keyword) }
        )
    }

    private var randomEmailDomainBinding: Binding<String> {
        Binding(
            get: { store.randomEmailDomain },
            set: { store.setRandomEmailDomain($0) }
        )
    }

    private func isFixedRule(_ question: String) -> Bool {
        ["姓名", "工号", "邮箱"].contains { question.contains($0) }
    }
}
