import Foundation
import Combine

struct FillRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var questionContains: String
    var answer: String
    var isEnabled: Bool = true
}

struct SubmissionPreset: Identifiable, Codable, Hashable {
    static let requiredQuestions = ["姓名", "工号", "邮箱"]

    var id: UUID = UUID()
    var name: String
    var rules: [FillRule]

    var usableRules: [FillRule] {
        rules.filter {
            $0.isEnabled &&
            !$0.questionContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isQueueReady: Bool {
        Self.requiredQuestions.allSatisfy { keyword in
            usableRules.contains { $0.questionContains.contains(keyword) }
        }
    }

    var completedFieldCount: Int {
        Self.requiredQuestions.filter { !answer(for: $0).isEmpty }.count
    }

    var missingQuestions: [String] {
        Self.requiredQuestions.filter { answer(for: $0).isEmpty }
    }

    func answer(for keyword: String) -> String {
        guard let rule = rules.first(where: { $0.questionContains.contains(keyword) }) else {
            return ""
        }
        return rule.answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DetectedQuestion: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let kind: String
}

enum SurveyPageState: Equatable {
    case loading
    case ready(questionCount: Int)
    case submitted(String)
    case closed(String)
    case captchaRequired
    case failed(String)
}

enum TestQueueState: Equatable {
    case idle
    case running(current: Int, total: Int, presetName: String)
    case completed(total: Int)
    case stopped(String)
}

struct UserNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum AutomationLogLevel: String, CaseIterable, Identifiable {
    case info
    case success
    case warning
    case error

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .info: return "信息"
        case .success: return "成功"
        case .warning: return "警告"
        case .error: return "失败"
        }
    }
}

enum AutomationLogCategory: String, CaseIterable, Identifiable {
    case system = "系统"
    case page = "页面"
    case fill = "填写"
    case submit = "提交"
    case batch = "批量"
    case security = "验证"

    var id: String { rawValue }
}

struct AutomationLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: AutomationLogLevel
    let category: AutomationLogCategory
    let message: String

    var title: String {
        guard let separator = message.firstIndex(of: "：") else { return message }
        return String(message[..<separator])
    }

    var detail: String? {
        guard let separator = message.firstIndex(of: "：") else { return nil }
        let value = String(message[message.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct ParallelRunSnapshot: Equatable {
    var completed = 0
    var total = 0
    var succeeded = 0
    var failed = 0
    var active = 0
    var detail = "尚未启动"

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

final class RuleStore: ObservableObject {
    static let presetCount = 10
    static let maximumSubmitDelaySeconds = 300

    private enum Key {
        static let rules = "fillRules.v1"
        static let presets = "submissionPresets.v2"
        static let selectedPresetID = "selectedPresetID.v2"
        static let surveyURL = "surveyURL.v1"
        static let autoFill = "autoFillOnLoad.v1"
        static let autoSubmit = "autoSubmitAfterFill.v1"
        static let submitDelay = "submitDelaySeconds.v1"
    }

    private let defaults: UserDefaults

    @Published var presets: [SubmissionPreset] {
        didSet { persistPresets() }
    }

    @Published var selectedPresetID: UUID {
        didSet { defaults.set(selectedPresetID.uuidString, forKey: Key.selectedPresetID) }
    }

    @Published var surveyURLString: String {
        didSet { defaults.set(surveyURLString, forKey: Key.surveyURL) }
    }

    @Published var autoFillOnLoad: Bool {
        didSet { defaults.set(autoFillOnLoad, forKey: Key.autoFill) }
    }

    @Published var autoSubmitAfterFill: Bool {
        didSet { defaults.set(autoSubmitAfterFill, forKey: Key.autoSubmit) }
    }

    @Published private(set) var submitDelaySeconds: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        surveyURLString = defaults.string(forKey: Key.surveyURL)
            ?? "https://www.wjx.cn/vm/moYL383.aspx"

        if defaults.object(forKey: Key.autoFill) == nil {
            autoFillOnLoad = true
        } else {
            autoFillOnLoad = defaults.bool(forKey: Key.autoFill)
        }

        if defaults.object(forKey: Key.autoSubmit) == nil {
            autoSubmitAfterFill = true
        } else {
            autoSubmitAfterFill = defaults.bool(forKey: Key.autoSubmit)
        }

        if let storedDelay = defaults.object(forKey: Key.submitDelay) as? NSNumber {
            submitDelaySeconds = min(
                max(storedDelay.intValue, 0),
                Self.maximumSubmitDelaySeconds
            )
        } else {
            submitDelaySeconds = 2
        }

        let rawPresets: [SubmissionPreset]
        if let data = defaults.data(forKey: Key.presets),
           let decoded = try? JSONDecoder().decode([SubmissionPreset].self, from: data),
           !decoded.isEmpty {
            rawPresets = decoded
        } else if let oldData = defaults.data(forKey: Key.rules),
                  let oldRules = try? JSONDecoder().decode([FillRule].self, from: oldData),
                  !oldRules.isEmpty {
            rawPresets = [SubmissionPreset(name: "预设 1", rules: oldRules)]
        } else {
            rawPresets = []
        }

        let loadedPresets = Self.makeTenPresets(from: rawPresets)
        presets = loadedPresets

        if let storedValue = defaults.string(forKey: Key.selectedPresetID),
           let storedID = UUID(uuidString: storedValue),
           loadedPresets.contains(where: { $0.id == storedID }) {
            selectedPresetID = storedID
        } else {
            selectedPresetID = loadedPresets[0].id
        }

        persistPresets()
    }

    var surveyURL: URL? {
        Self.validatedSurveyURL(from: surveyURLString)
    }

    static func validatedSurveyURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(),
              url.scheme == "https",
              host == "wjx.cn" || host.hasSuffix(".wjx.cn") else {
            return nil
        }
        return url
    }

    var selectedPresetIndex: Int? {
        presets.firstIndex(where: { $0.id == selectedPresetID })
    }

    var selectedPreset: SubmissionPreset? {
        guard let index = selectedPresetIndex else { return nil }
        return presets[index]
    }

    var queuePresets: [SubmissionPreset] {
        Array(presets.filter { $0.isQueueReady }.prefix(Self.presetCount))
    }

    var parallelValidationMessage: String? {
        guard queuePresets.count == Self.presetCount else {
            return "请完整填写全部 10 组"
        }

        for keyword in SubmissionPreset.requiredQuestions {
            let values = queuePresets.map {
                $0.answer(for: keyword).lowercased()
            }
            if Set(values).count != Self.presetCount {
                return "10 组的\(keyword)不能重复"
            }
        }
        return nil
    }

    var isParallelReady: Bool {
        parallelValidationMessage == nil
    }

    func validationMessage(for preset: SubmissionPreset) -> String? {
        if !preset.missingQuestions.isEmpty {
            return "缺少" + preset.missingQuestions.joined(separator: "、")
        }

        let duplicateQuestions = SubmissionPreset.requiredQuestions.filter { keyword in
            let value = preset.answer(for: keyword).lowercased()
            guard !value.isEmpty else { return false }
            return presets.filter { $0.answer(for: keyword).lowercased() == value }.count > 1
        }
        if !duplicateQuestions.isEmpty {
            return duplicateQuestions.joined(separator: "、") + "重复"
        }
        return nil
    }

    func fixedAnswer(for keyword: String, presetID: UUID) -> String {
        guard let presetIndex = presets.firstIndex(where: { $0.id == presetID }),
              let ruleIndex = fixedRuleIndex(keyword: keyword, presetIndex: presetIndex) else {
            return ""
        }
        return presets[presetIndex].rules[ruleIndex].answer
    }

    func setFixedAnswer(_ value: String, for keyword: String, presetID: UUID) {
        guard let presetIndex = presets.firstIndex(where: { $0.id == presetID }) else { return }
        let ruleIndex = ensureFixedRule(keyword: keyword, presetIndex: presetIndex)
        presets[presetIndex].rules[ruleIndex].answer = value
        presets[presetIndex].rules[ruleIndex].isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearPreset(_ presetID: UUID) {
        guard let presetIndex = presets.firstIndex(where: { $0.id == presetID }) else { return }
        for keyword in SubmissionPreset.requiredQuestions {
            let ruleIndex = ensureFixedRule(keyword: keyword, presetIndex: presetIndex)
            presets[presetIndex].rules[ruleIndex].answer = ""
            presets[presetIndex].rules[ruleIndex].isEnabled = false
        }
    }

    func setSubmitDelaySeconds(_ value: Int) {
        let clampedValue = min(max(value, 0), Self.maximumSubmitDelaySeconds)
        submitDelaySeconds = clampedValue
        defaults.set(clampedValue, forKey: Key.submitDelay)
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Key.presets)
    }

    private func fixedRuleIndex(keyword: String, presetIndex: Int) -> Int? {
        presets[presetIndex].rules.firstIndex {
            $0.questionContains.trimmingCharacters(in: .whitespacesAndNewlines).contains(keyword)
        }
    }

    private func ensureFixedRule(keyword: String, presetIndex: Int) -> Int {
        if let existing = fixedRuleIndex(keyword: keyword, presetIndex: presetIndex) {
            return existing
        }
        presets[presetIndex].rules.append(
            FillRule(questionContains: keyword, answer: "", isEnabled: false)
        )
        return presets[presetIndex].rules.count - 1
    }

    private static func makeTenPresets(from existing: [SubmissionPreset]) -> [SubmissionPreset] {
        (0..<presetCount).map { index in
            if index < existing.count {
                return normalizedPreset(existing[index], slot: index + 1)
            }
            return emptyPreset(slot: index + 1)
        }
    }

    private static func emptyPreset(slot: Int) -> SubmissionPreset {
        SubmissionPreset(
            name: "预设 \(slot)",
            rules: SubmissionPreset.requiredQuestions.map {
                FillRule(questionContains: $0, answer: "", isEnabled: false)
            }
        )
    }

    private static func normalizedPreset(_ preset: SubmissionPreset, slot: Int) -> SubmissionPreset {
        let rules = SubmissionPreset.requiredQuestions.map { keyword -> FillRule in
            let oldRule = preset.rules.first { $0.questionContains.contains(keyword) }
            var answer = oldRule?.answer ?? ""

            // 旧版随机邮箱占位符不能作为固定邮箱使用，迁移时留空让用户填写。
            if keyword == "邮箱" {
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("{{random_email") && trimmed.hasSuffix("}}") {
                    answer = ""
                }
            }

            return FillRule(
                id: oldRule?.id ?? UUID(),
                questionContains: keyword,
                answer: answer,
                isEnabled: !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        return SubmissionPreset(id: preset.id, name: "预设 \(slot)", rules: rules)
    }
}

final class SurveyPageSession: ObservableObject, Identifiable {
    let id: UUID
    let pageNumber: Int
    @Published var title: String
    @Published var surveyURLString: String
    let selectedPresetID: UUID
    @Published var autoFillOnLoad: Bool
    @Published var autoSubmitAfterFill: Bool
    @Published var submitDelaySeconds: Int
    let controller: SurveyWebController

    init(
        id: UUID = UUID(),
        pageNumber: Int,
        title: String,
        surveyURLString: String,
        selectedPresetID: UUID,
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int,
        controller: SurveyWebController = SurveyWebController()
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.title = title
        self.surveyURLString = surveyURLString
        self.selectedPresetID = selectedPresetID
        self.autoFillOnLoad = autoFillOnLoad
        self.autoSubmitAfterFill = autoSubmitAfterFill
        self.submitDelaySeconds = submitDelaySeconds
        self.controller = controller
    }

    var surveyURL: URL? {
        RuleStore.validatedSurveyURL(from: surveyURLString)
    }
}

final class SurveyWorkspace: ObservableObject {
    static let maximumPageCount = 4

    @Published private(set) var pages: [SurveyPageSession]
    @Published var selectedPageID: UUID?

    init(
        defaultURLString: String,
        defaultPresetID: UUID,
        presetIDs: [UUID],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        let firstPage = SurveyPageSession(
            pageNumber: 1,
            title: "页面 1",
            surveyURLString: defaultURLString,
            selectedPresetID: Self.correspondingPresetID(
                for: 1,
                presetIDs: presetIDs,
                fallback: defaultPresetID
            ),
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
        pages = [firstPage]
        selectedPageID = firstPage.id
    }

    var selectedPage: SurveyPageSession? {
        guard let selectedPageID else { return pages.first }
        return pages.first { $0.id == selectedPageID } ?? pages.first
    }

    var canAddPage: Bool {
        pages.count < Self.maximumPageCount
    }

    @discardableResult
    func addPage(
        defaultURLString: String,
        defaultPresetID: UUID,
        presetIDs: [UUID],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) -> SurveyPageSession? {
        guard canAddPage, let pageNumber = nextPageNumber() else { return nil }
        let page = SurveyPageSession(
            pageNumber: pageNumber,
            title: "页面 \(pageNumber)",
            surveyURLString: defaultURLString,
            selectedPresetID: Self.correspondingPresetID(
                for: pageNumber,
                presetIDs: presetIDs,
                fallback: defaultPresetID
            ),
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
        pages.append(page)
        pages.sort { $0.pageNumber < $1.pageNumber }
        selectedPageID = page.id
        return page
    }

    @discardableResult
    func duplicateSelectedPage(presetIDs: [UUID]) -> SurveyPageSession? {
        guard canAddPage,
              let selectedPage,
              let pageNumber = nextPageNumber() else { return nil }
        let page = SurveyPageSession(
            pageNumber: pageNumber,
            title: "页面 \(pageNumber)",
            surveyURLString: selectedPage.surveyURLString,
            selectedPresetID: Self.correspondingPresetID(
                for: pageNumber,
                presetIDs: presetIDs,
                fallback: selectedPage.selectedPresetID
            ),
            autoFillOnLoad: selectedPage.autoFillOnLoad,
            autoSubmitAfterFill: selectedPage.autoSubmitAfterFill,
            submitDelaySeconds: selectedPage.submitDelaySeconds
        )
        pages.append(page)
        pages.sort { $0.pageNumber < $1.pageNumber }
        selectedPageID = page.id
        return page
    }

    func closePage(_ pageID: UUID) {
        guard pages.count > 1,
              let index = pages.firstIndex(where: { $0.id == pageID }) else { return }

        let page = pages[index]
        page.controller.shutdown()
        pages.remove(at: index)

        if selectedPageID == pageID {
            let nextIndex = min(index, pages.count - 1)
            selectedPageID = pages[nextIndex].id
        }
    }

    private func nextPageNumber() -> Int? {
        for number in 1...Self.maximumPageCount {
            if !pages.contains(where: { $0.pageNumber == number }) {
                return number
            }
        }
        return nil
    }

    private static func correspondingPresetID(
        for pageNumber: Int,
        presetIDs: [UUID],
        fallback: UUID
    ) -> UUID {
        let index = pageNumber - 1
        guard presetIDs.indices.contains(index) else { return fallback }
        return presetIDs[index]
    }
}
