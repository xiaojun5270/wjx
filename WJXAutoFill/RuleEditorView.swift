import SwiftUI
import UIKit

struct RuleEditorView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case survey = "问卷"
        case preset = "预设"
        case batch = "批量"

        var id: String { rawValue }
    }

    @ObservedObject var store: RuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .survey
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("设置页面", selection: $page) {
                    ForEach(Page.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                switch page {
                case .survey:
                    surveySettings
                case .preset:
                    presetEditor
                case .batch:
                    batchOverview
                }
            }
            .navigationTitle("问卷与预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "清空当前预设？",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空姓名、工号和邮箱", role: .destructive) {
                    store.clearPreset(store.selectedPresetID)
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var surveySettings: some View {
        Form {
            Section("问卷地址") {
                TextField("https://www.wjx.cn/...", text: $store.surveyURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 8) {
                    Image(systemName: store.surveyURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(store.surveyURL == nil ? Color.orange : Color.green)
                    Text(store.surveyURL == nil ? "地址无效" : (store.surveyURL?.host ?? "地址有效"))
                        .font(.subheadline)
                    Spacer()
                }
            }

            Section("自动流程") {
                Toggle(isOn: $store.autoFillOnLoad) {
                    Label("页面加载后自动填写", systemImage: "wand.and.stars")
                }

                Toggle(isOn: $store.autoSubmitAfterFill) {
                    Label("填写完成后自动提交", systemImage: "paperplane")
                }

                LabeledContent {
                    Text("2 秒")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("提交等待", systemImage: "timer")
                }
            }

            Section("当前单次预设") {
                presetPicker

                if let preset = store.selectedPreset {
                    HStack {
                        Text("数据完整度")
                        Spacer()
                        Text("\(preset.completedFieldCount) / 3")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(preset.isQueueReady ? Color.green : Color.orange)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var presetEditor: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Button {
                        moveSelection(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 28, height: 28)
                    }
                    .disabled(selectedIndex == 0)
                    .help("上一个预设")

                    Spacer()
                    presetPicker
                    Spacer()

                    Button {
                        moveSelection(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 28, height: 28)
                    }
                    .disabled(selectedIndex >= store.presets.count - 1)
                    .help("下一个预设")
                }
            }

            if let preset = store.selectedPreset {
                Section {
                    presetStatus(preset)
                }

                Section("固定提交内容") {
                    answerField(
                        title: "姓名",
                        icon: "person",
                        placeholder: "请输入姓名",
                        contentType: .name,
                        keyboard: .default
                    )

                    answerField(
                        title: "工号",
                        icon: "number",
                        placeholder: "请输入工号",
                        contentType: nil,
                        keyboard: .asciiCapable
                    )

                    answerField(
                        title: "邮箱",
                        icon: "envelope",
                        placeholder: "请输入固定邮箱",
                        contentType: .emailAddress,
                        keyboard: .emailAddress
                    )
                }

                Section {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("清空当前预设", systemImage: "trash")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var batchOverview: some View {
        Form {
            Section("批量状态") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("完整预设")
                        Spacer()
                        Text("\(store.queuePresets.count) / \(RuleStore.presetCount)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    ProgressView(
                        value: Double(store.queuePresets.count),
                        total: Double(RuleStore.presetCount)
                    )
                    .tint(store.isParallelReady ? .green : .orange)
                }

                HStack(spacing: 8) {
                    Image(systemName: store.isParallelReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.isParallelReady ? Color.green : Color.orange)
                    Text(store.parallelValidationMessage ?? "10 组数据检查通过")
                        .font(.subheadline)
                }

                if let firstInvalidPreset {
                    Button {
                        store.selectedPresetID = firstInvalidPreset.id
                        page = .preset
                    } label: {
                        Label("检查 \(firstInvalidPreset.name)", systemImage: "arrow.right.circle")
                    }
                }
            }

            Section("10 组预设") {
                ForEach(store.presets) { preset in
                    Button {
                        store.selectedPresetID = preset.id
                        page = .preset
                    } label: {
                        HStack(spacing: 11) {
                            ZStack {
                                Circle()
                                    .fill(statusColor(for: preset).opacity(0.14))
                                Text("\(presetNumber(for: preset))")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(statusColor(for: preset))
                            }
                            .frame(width: 30, height: 30)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(store.validationMessage(for: preset) ?? "数据完整且不重复")
                                    .font(.caption)
                                    .foregroundStyle(store.validationMessage(for: preset) == nil ? Color.secondary : Color.orange)
                                    .lineLimit(1)
                            }

                            Spacer()
                            Text("\(preset.completedFieldCount)/3")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("执行参数") {
                LabeledContent("预设数量", value: "10")
                LabeledContent("并行任务", value: "10")
                LabeledContent("安全验证", value: "出现时停止")
            }
        }
    }

    private var presetPicker: some View {
        Menu {
            ForEach(store.presets) { preset in
                Button {
                    store.selectedPresetID = preset.id
                } label: {
                    Label(
                        preset.name,
                        systemImage: preset.isQueueReady ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(store.selectedPreset?.name ?? "选择预设")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presetStatus(_ preset: SubmissionPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    store.validationMessage(for: preset) ?? "当前预设可用",
                    systemImage: store.validationMessage(for: preset) == nil
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(store.validationMessage(for: preset) == nil ? Color.green : Color.orange)
                Spacer()
                Text("\(preset.completedFieldCount) / 3")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(preset.completedFieldCount), total: 3)
                .tint(preset.isQueueReady ? .green : .orange)
        }
    }

    private func answerField(
        title: String,
        icon: String,
        placeholder: String,
        contentType: UITextContentType?,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(
                placeholder,
                text: answerBinding(presetID: store.selectedPresetID, keyword: title)
            )
            .textFieldStyle(.roundedBorder)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 2)
    }

    private var selectedIndex: Int {
        store.selectedPresetIndex ?? 0
    }

    private var firstInvalidPreset: SubmissionPreset? {
        store.presets.first { store.validationMessage(for: $0) != nil }
    }

    private func moveSelection(by offset: Int) {
        let target = selectedIndex + offset
        guard store.presets.indices.contains(target) else { return }
        store.selectedPresetID = store.presets[target].id
    }

    private func answerBinding(presetID: UUID, keyword: String) -> Binding<String> {
        Binding(
            get: { store.fixedAnswer(for: keyword, presetID: presetID) },
            set: { store.setFixedAnswer($0, for: keyword, presetID: presetID) }
        )
    }

    private func statusColor(for preset: SubmissionPreset) -> Color {
        store.validationMessage(for: preset) == nil ? .green : .orange
    }

    private func presetNumber(for preset: SubmissionPreset) -> Int {
        (store.presets.firstIndex(where: { $0.id == preset.id }) ?? 0) + 1
    }
}
