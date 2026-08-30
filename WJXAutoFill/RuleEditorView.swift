import SwiftUI
import UIKit

struct RuleEditorView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case survey = "问卷"
        case preset = "预设"
        case batch = "批量"
        case headers = "请求头"

        var id: String { rawValue }
    }

    private struct BatchField: Hashable {
        let presetID: UUID
        let keyword: String
    }

    @ObservedObject var store: RuleStore
    @Binding var surveyURLString: String
    @Binding var selectedPresetID: UUID
    @Binding var autoFillOnLoad: Bool
    @Binding var autoSubmitAfterFill: Bool
    @Binding var submitDelaySeconds: Int
    let isPresetSelectionLocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .survey
    @State private var showingClearConfirmation = false
    @State private var presetPendingClear: UUID?
    @FocusState private var focusedBatchField: BatchField?

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
                case .headers:
                    RequestHeaderProfilesView(store: store)
                }
            }
            .navigationTitle("问卷与预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起") { focusedBatchField = nil }
                }
            }
            .confirmationDialog(
                "清空这组预设？",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空姓名、工号和邮箱", role: .destructive) {
                    if let presetID = presetPendingClear {
                        store.clearPreset(presetID)
                    }
                    presetPendingClear = nil
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var surveySettings: some View {
        Form {
            Section("问卷地址") {
                TextField("https://www.wjx.cn/...", text: $surveyURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 8) {
                    Image(systemName: surveyURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(surveyURL == nil ? Color.orange : Color.green)
                    Text(surveyURL == nil ? "地址无效" : (surveyURL?.host ?? "地址有效"))
                        .font(.subheadline)
                    Spacer()
                }
            }

            Section("自动流程") {
                Toggle(isOn: $autoFillOnLoad) {
                    Label("页面加载后自动填写", systemImage: "wand.and.stars")
                }

                Toggle(isOn: $autoSubmitAfterFill) {
                    Label("单组填写后自动提交", systemImage: "paperplane")
                }

                submitDelayEditor
            }

            Section("当前单次预设") {
                if isPresetSelectionLocked {
                    lockedPresetLabel
                } else {
                    presetPicker
                }

                if let preset = selectedPreset {
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
                if isPresetSelectionLocked {
                    lockedPresetLabel
                } else {
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
            }

            if let preset = selectedPreset {
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
                        presetPendingClear = selectedPresetID
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                batchSummary

                Text("10 组提交内容")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(store.presets) { preset in
                    batchPresetEditor(preset)
                }
            }
            .padding(14)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var batchSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("批量数据")
                        .font(.subheadline.weight(.semibold))
                    Text(store.parallelValidationMessage ?? "10 组数据检查通过")
                        .font(.caption)
                        .foregroundStyle(store.isParallelReady ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(store.queuePresets.count) / \(RuleStore.presetCount)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(store.isParallelReady ? Color.green : Color.orange)
            }

            ProgressView(
                value: Double(store.queuePresets.count),
                total: Double(RuleStore.presetCount)
            )
            .tint(store.isParallelReady ? .green : .orange)

        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func batchPresetEditor(_ preset: SubmissionPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor(for: preset).opacity(0.14))
                    Text("\(presetNumber(for: preset))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(statusColor(for: preset))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.subheadline.weight(.semibold))
                    Text(store.validationMessage(for: preset) ?? "数据完整且不重复")
                        .font(.caption)
                        .foregroundStyle(store.validationMessage(for: preset) == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }

                Spacer()

                if isPresetSelectionLocked {
                    Image(systemName: selectedPresetID == preset.id ? "checkmark.circle.fill" : "circle")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(selectedPresetID == preset.id ? Color.green : Color.secondary)
                        .accessibilityLabel(
                            selectedPresetID == preset.id ? "当前页面对应预设" : "其他页面预设"
                        )
                } else {
                    Button {
                        selectedPresetID = preset.id
                    } label: {
                        Image(systemName: selectedPresetID == preset.id ? "checkmark.circle.fill" : "circle")
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(selectedPresetID == preset.id ? Color.green : Color.secondary)
                    .accessibilityLabel("设为单次填写预设")
                    .help("设为单次填写预设")
                }

                Button(role: .destructive) {
                    presetPendingClear = preset.id
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("清空该预设")
                .help("清空该预设")
            }

            HStack(alignment: .top, spacing: 10) {
                batchAnswerField(
                    title: "姓名",
                    placeholder: "姓名",
                    presetID: preset.id,
                    keyboard: .default,
                    contentType: .name
                )
                batchAnswerField(
                    title: "工号",
                    placeholder: "工号",
                    presetID: preset.id,
                    keyboard: .asciiCapable,
                    contentType: nil
                )
            }

            batchAnswerField(
                title: "邮箱",
                placeholder: "固定邮箱",
                presetID: preset.id,
                keyboard: .emailAddress,
                contentType: .emailAddress
            )
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor(for: preset).opacity(0.18), lineWidth: 1)
        }
    }

    private func batchAnswerField(
        title: String,
        placeholder: String,
        presetID: UUID,
        keyboard: UIKeyboardType,
        contentType: UITextContentType?
    ) -> some View {
        let field = BatchField(presetID: presetID, keyword: title)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: answerBinding(presetID: presetID, keyword: title))
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedBatchField, equals: field)
                .submitLabel(isLastBatchField(field) ? .done : .next)
                .onSubmit { advanceBatchFocus(after: field) }
        }
        .frame(maxWidth: .infinity)
    }

    private var submitDelayEditor: some View {
        HStack(spacing: 9) {
            Label("单组提交等待", systemImage: "timer")
                .font(.subheadline)
            Spacer()
            TextField("0", value: submitDelayBinding, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Text("秒")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Stepper(
                "单组提交等待",
                value: submitDelayBinding,
                in: 0...RuleStore.maximumSubmitDelaySeconds
            )
            .labelsHidden()
        }
    }

    private var presetPicker: some View {
        Menu {
            ForEach(store.presets) { preset in
                Button {
                    selectedPresetID = preset.id
                } label: {
                    Label(
                        preset.name,
                        systemImage: preset.isQueueReady ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(selectedPreset?.name ?? "选择预设")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lockedPresetLabel: some View {
        HStack(spacing: 8) {
            Label(selectedPreset?.name ?? "对应预设", systemImage: "lock.fill")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("与页面编号对应")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                text: answerBinding(presetID: selectedPresetID, keyword: title)
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
        store.presets.firstIndex(where: { $0.id == selectedPresetID }) ?? 0
    }

    private var selectedPreset: SubmissionPreset? {
        store.presets.first { $0.id == selectedPresetID } ?? store.presets.first
    }

    private var surveyURL: URL? {
        RuleStore.validatedSurveyURL(from: surveyURLString)
    }

    private func moveSelection(by offset: Int) {
        let target = selectedIndex + offset
        guard store.presets.indices.contains(target) else { return }
        selectedPresetID = store.presets[target].id
    }

    private func answerBinding(presetID: UUID, keyword: String) -> Binding<String> {
        Binding(
            get: { store.fixedAnswer(for: keyword, presetID: presetID) },
            set: { store.setFixedAnswer($0, for: keyword, presetID: presetID) }
        )
    }

    private var submitDelayBinding: Binding<Int> {
        Binding(
            get: { submitDelaySeconds },
            set: {
                submitDelaySeconds = min(
                    max($0, 0),
                    RuleStore.maximumSubmitDelaySeconds
                )
            }
        )
    }

    private var orderedBatchFields: [BatchField] {
        store.presets.flatMap { preset in
            SubmissionPreset.requiredQuestions.map {
                BatchField(presetID: preset.id, keyword: $0)
            }
        }
    }

    private func isLastBatchField(_ field: BatchField) -> Bool {
        orderedBatchFields.last == field
    }

    private func advanceBatchFocus(after field: BatchField) {
        let fields = orderedBatchFields
        guard let currentIndex = fields.firstIndex(of: field),
              fields.indices.contains(currentIndex + 1) else {
            focusedBatchField = nil
            return
        }
        focusedBatchField = fields[currentIndex + 1]
    }

    private func statusColor(for preset: SubmissionPreset) -> Color {
        store.validationMessage(for: preset) == nil ? .green : .orange
    }

    private func presetNumber(for preset: SubmissionPreset) -> Int {
        (store.presets.firstIndex(where: { $0.id == preset.id }) ?? 0) + 1
    }
}
