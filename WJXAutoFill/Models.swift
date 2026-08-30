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
        static let officialAPISettings = "officialAPISettings.v1"
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

    @Published var officialAPISettings: WJXOfficialAPISettings {
        didSet { persistOfficialAPISettings() }
    }

    @Published var officialAPIAccessToken: String {
        didSet { WJXAPICredentialStore.storeAccessToken(officialAPIAccessToken) }
    }

    @Published var requestHeaderProfiles: [RequestHeaderProfile] {
        didSet { RequestHeaderProfileStore.store(requestHeaderProfiles) }
    }

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

        if let data = defaults.data(forKey: Key.officialAPISettings),
           let decoded = try? JSONDecoder().decode(WJXOfficialAPISettings.self, from: data) {
            officialAPISettings = decoded
        } else {
            officialAPISettings = .defaultValue
        }
        officialAPIAccessToken = WJXAPICredentialStore.readAccessToken()
        requestHeaderProfiles = RequestHeaderProfileStore.read()

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

    var officialAPIValidationMessage: String? {
        if let presetMessage = parallelValidationMessage {
            return presetMessage
        }
        return officialAPISettings.validationMessage(accessToken: officialAPIAccessToken)
    }

    var isOfficialAPIReady: Bool {
        officialAPISettings.isEnabled && officialAPIValidationMessage == nil
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

    func updateOfficialAPISettings(
        _ update: (inout WJXOfficialAPISettings) -> Void
    ) {
        var settings = officialAPISettings
        update(&settings)
        settings.nameQuestionNumber = max(settings.nameQuestionNumber, 1)
        settings.employeeQuestionNumber = max(settings.employeeQuestionNumber, 1)
        settings.emailQuestionNumber = max(settings.emailQuestionNumber, 0)
        settings.inputCostTimeSeconds = min(
            max(settings.inputCostTimeSeconds, 2),
            86_400
        )
        officialAPISettings = settings
    }

    func upsertRequestHeaderProfile(_ profile: RequestHeaderProfile) {
        var normalized = profile
        normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.urlPattern = profile.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.headers = profile.headers.map { header in
            var value = header
            value.name = header.normalizedName
            value.value = header.value.trimmingCharacters(in: .newlines)
            if value.action == .delete { value.value = "" }
            return value
        }
        if let index = requestHeaderProfiles.firstIndex(where: { $0.id == normalized.id }) {
            requestHeaderProfiles[index] = normalized
        } else {
            requestHeaderProfiles.append(normalized)
        }
    }

    func setRequestHeaderProfileEnabled(_ profileID: UUID, enabled: Bool) {
        guard let index = requestHeaderProfiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        requestHeaderProfiles[index].isEnabled = enabled
    }

    func cloneRequestHeaderProfile(_ profileID: UUID) {
        guard var profile = requestHeaderProfiles.first(where: { $0.id == profileID }) else {
            return
        }
        profile.id = UUID()
        profile.name += " 副本"
        profile.headers = profile.headers.map { header in
            var copy = header
            copy.id = UUID()
            return copy
        }
        requestHeaderProfiles.append(profile)
    }

    func deleteRequestHeaderProfile(_ profileID: UUID) {
        requestHeaderProfiles.removeAll { $0.id == profileID }
    }

    private func persistPresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Key.presets)
    }

    private func persistOfficialAPISettings() {
        guard let data = try? JSONEncoder().encode(officialAPISettings) else { return }
        defaults.set(data, forKey: Key.officialAPISettings)
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
    private enum Key {
        static let snapshot = "surveyWorkspace.v1"
    }

    private struct PageSnapshot: Codable {
        let id: UUID
        let pageNumber: Int
        let title: String
        let surveyURLString: String
        let selectedPresetID: UUID
        let autoFillOnLoad: Bool
        let autoSubmitAfterFill: Bool
        let submitDelaySeconds: Int
    }

    private struct WorkspaceSnapshot: Codable {
        let pages: [PageSnapshot]
        let selectedPageID: UUID?
        /// 旧版本快照没有这两个字段，用可选类型保证仍能解码。
        let syncSubmitEnabled: Bool?
        let autoSubmitBackup: [String: Bool]?
    }

    /// 一次同步提交的计划：哪些页面可以立刻提交，哪些被跳过以及原因。
    struct SyncSubmitPlan {
        struct SkippedPage: Identifiable {
            let id: UUID
            let pageNumber: Int
            let reason: String
        }

        var readyPageIDs: [UUID] = []
        var readyPageNumbers: [Int] = []
        var skipped: [SkippedPage] = []

        var isEmpty: Bool { readyPageIDs.isEmpty }
    }

    @Published private(set) var pages: [SurveyPageSession]
    @Published var selectedPageID: UUID? {
        didSet { persistWorkspace() }
    }

    /// 同步提交模式：打开后各页面只自动填写并停在填好状态，等用户手动一次性触发提交。
    /// 用 `setSyncSubmitEnabled(_:)` 修改，避免 init 里恢复状态时误改各页开关。
    @Published private(set) var isSyncSubmitEnabled = false

    private let defaults: UserDefaults
    private var pageObservers: [UUID: AnyCancellable] = [:]
    /// 进入同步提交模式前各页面原本的「填写后自动提交」开关，退出时用于还原。
    private var autoSubmitBackup: [UUID: Bool] = [:]

    init(
        defaultURLString: String,
        defaultPresetID: UUID,
        presetIDs: [UUID],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults

        let restoredSnapshot = defaults.data(forKey: Key.snapshot)
            .flatMap { try? JSONDecoder().decode(WorkspaceSnapshot.self, from: $0) }
        let restoredPages = restoredSnapshot.map {
            Self.restorePages(
                from: $0.pages,
                presetIDs: presetIDs,
                fallbackPresetID: defaultPresetID
            )
        } ?? []

        if restoredPages.isEmpty {
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
        } else {
            pages = restoredPages
            let restoredSelectedID = restoredSnapshot?.selectedPageID
            selectedPageID = restoredSelectedID.flatMap { selectedID in
                restoredPages.contains(where: { $0.id == selectedID }) ? selectedID : nil
            } ?? restoredPages.first?.id
        }

        // 直接在 init 里赋值不会触发 didSet，所以这里只恢复状态，不重复应用开关。
        isSyncSubmitEnabled = restoredSnapshot?.syncSubmitEnabled ?? false
        if isSyncSubmitEnabled, let backup = restoredSnapshot?.autoSubmitBackup {
            let livePageIDs = Set(pages.map(\.id))
            autoSubmitBackup = backup.reduce(into: [UUID: Bool]()) { result, entry in
                guard let id = UUID(uuidString: entry.key), livePageIDs.contains(id) else { return }
                result[id] = entry.value
            }
        }

        observeAllPages()
        persistWorkspace()
    }

    var selectedPage: SurveyPageSession? {
        guard let selectedPageID else { return pages.first }
        return pages.first { $0.id == selectedPageID } ?? pages.first
    }

    func hasNextPage(after pageID: UUID) -> Bool {
        guard let currentIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return false
        }
        return pages.index(after: currentIndex) < pages.endIndex
    }

    @discardableResult
    func selectNextPage(after pageID: UUID) -> Bool {
        guard selectedPageID == pageID,
              let currentIndex = pages.firstIndex(where: { $0.id == pageID }) else {
            return false
        }
        let nextIndex = pages.index(after: currentIndex)
        guard pages.indices.contains(nextIndex) else { return false }
        selectedPageID = pages[nextIndex].id
        return true
    }

    func synchronizeSurveyURL(_ value: String) {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RuleStore.validatedSurveyURL(from: normalizedValue) != nil else { return }

        var didChange = false
        for page in pages where page.surveyURLString != normalizedValue {
            page.surveyURLString = normalizedValue
            didChange = true
        }
        if didChange {
            persistWorkspace()
        }
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
        guard let pageNumber = nextPageNumber() else { return nil }
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
        prepareForSyncSubmitModeIfNeeded(page)
        pages.append(page)
        pages.sort { $0.pageNumber < $1.pageNumber }
        observePage(page)
        selectedPageID = page.id
        return page
    }

    @discardableResult
    func duplicateSelectedPage(presetIDs: [UUID]) -> SurveyPageSession? {
        guard let selectedPage,
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
        prepareForSyncSubmitModeIfNeeded(page)
        pages.append(page)
        pages.sort { $0.pageNumber < $1.pageNumber }
        observePage(page)
        selectedPageID = page.id
        return page
    }

    func closePage(_ pageID: UUID) {
        guard pages.count > 1,
              let index = pages.firstIndex(where: { $0.id == pageID }) else { return }

        let page = pages[index]
        page.controller.shutdown()
        pageObservers.removeValue(forKey: pageID)
        autoSubmitBackup.removeValue(forKey: pageID)
        pages.remove(at: index)

        if selectedPageID == pageID {
            let nextIndex = min(index, pages.count - 1)
            selectedPageID = pages[nextIndex].id
        } else {
            persistWorkspace()
        }
    }

    // MARK: - 同步提交

    func setSyncSubmitEnabled(_ enabled: Bool) {
        guard enabled != isSyncSubmitEnabled else { return }
        isSyncSubmitEnabled = enabled
        applySyncSubmitMode(enabled: enabled)
        persistWorkspace()
    }

    /// 切换同步提交模式：打开时把各页面的自动提交暂时关掉（记下原值），关闭时还原。
    private func applySyncSubmitMode(enabled: Bool) {
        if enabled {
            for page in pages where page.autoSubmitAfterFill {
                autoSubmitBackup[page.id] = true
                page.autoSubmitAfterFill = false
            }
        } else {
            for page in pages {
                guard let restored = autoSubmitBackup[page.id] else { continue }
                page.autoSubmitAfterFill = restored
            }
            autoSubmitBackup.removeAll()
        }
    }

    /// 同步提交模式下新增的页面同样只填不交。
    private func prepareForSyncSubmitModeIfNeeded(_ page: SurveyPageSession) {
        guard isSyncSubmitEnabled, page.autoSubmitAfterFill else { return }
        autoSubmitBackup[page.id] = true
        page.autoSubmitAfterFill = false
    }

    /// 先算出这一次同步提交会碰到哪些页面，供确认弹窗展示，不产生任何副作用。
    func syncSubmitPlan() -> SyncSubmitPlan {
        var plan = SyncSubmitPlan()
        for page in pages {
            if let reason = page.controller.syncSubmitBlockReason {
                plan.skipped.append(
                    SyncSubmitPlan.SkippedPage(
                        id: page.id,
                        pageNumber: page.pageNumber,
                        reason: reason
                    )
                )
            } else {
                plan.readyPageIDs.append(page.id)
                plan.readyPageNumbers.append(page.pageNumber)
            }
        }
        return plan
    }

    /// 按计划提交：在同一轮主线程循环里让每一页各自点击自己页面的提交按钮。
    /// 这里不合并请求、不代发请求，只是把多次真实点击安排在同一时刻。
    @discardableResult
    func submitPagesTogether(_ plan: SyncSubmitPlan) -> [Int] {
        for skipped in plan.skipped {
            guard let page = pages.first(where: { $0.id == skipped.id }) else { continue }
            page.controller.noteSyncSubmitSkipped(reason: skipped.reason)
        }

        let readyPages = plan.readyPageIDs.compactMap { pageID in
            pages.first { $0.id == pageID }
        }
        // 触发前再自检一次，避免确认弹窗停留期间页面状态变化。
        let submittablePages = readyPages.filter { page in
            guard let reason = page.controller.syncSubmitBlockReason else { return true }
            page.controller.noteSyncSubmitSkipped(reason: reason)
            return false
        }

        for page in submittablePages {
            page.controller.submitOnce(showScheduledNotice: false, source: "同步提交")
        }
        return submittablePages.map(\.pageNumber)
    }

    private func nextPageNumber() -> Int? {
        let usedNumbers = Set(pages.map(\.pageNumber))
        var number = 1
        while usedNumbers.contains(number) {
            guard number < Int.max else { return nil }
            number += 1
        }
        return number
    }

    private static func correspondingPresetID(
        for pageNumber: Int,
        presetIDs: [UUID],
        fallback: UUID
    ) -> UUID {
        guard pageNumber > 0, !presetIDs.isEmpty else { return fallback }
        let index = (pageNumber - 1) % presetIDs.count
        return presetIDs[index]
    }

    private static func restorePages(
        from snapshots: [PageSnapshot],
        presetIDs: [UUID],
        fallbackPresetID: UUID
    ) -> [SurveyPageSession] {
        var usedIDs = Set<UUID>()
        var usedNumbers = Set<Int>()

        return snapshots
            .sorted { $0.pageNumber < $1.pageNumber }
            .compactMap { snapshot in
                guard snapshot.pageNumber > 0,
                      usedIDs.insert(snapshot.id).inserted,
                      usedNumbers.insert(snapshot.pageNumber).inserted else {
                    return nil
                }

                return SurveyPageSession(
                    id: snapshot.id,
                    pageNumber: snapshot.pageNumber,
                    title: snapshot.title.isEmpty ? "页面 \(snapshot.pageNumber)" : snapshot.title,
                    surveyURLString: snapshot.surveyURLString,
                    selectedPresetID: Self.correspondingPresetID(
                        for: snapshot.pageNumber,
                        presetIDs: presetIDs,
                        fallback: snapshot.selectedPresetID
                    ),
                    autoFillOnLoad: snapshot.autoFillOnLoad,
                    autoSubmitAfterFill: snapshot.autoSubmitAfterFill,
                    submitDelaySeconds: min(
                        max(snapshot.submitDelaySeconds, 0),
                        RuleStore.maximumSubmitDelaySeconds
                    )
                )
            }
    }

    private func observeAllPages() {
        pages.forEach(observePage)
    }

    private func observePage(_ page: SurveyPageSession) {
        pageObservers[page.id] = page.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.persistWorkspace()
            }
        }
    }

    private func persistWorkspace() {
        guard !pages.isEmpty else { return }
        let snapshot = WorkspaceSnapshot(
            pages: pages.map {
                PageSnapshot(
                    id: $0.id,
                    pageNumber: $0.pageNumber,
                    title: $0.title,
                    surveyURLString: $0.surveyURLString,
                    selectedPresetID: $0.selectedPresetID,
                    autoFillOnLoad: $0.autoFillOnLoad,
                    autoSubmitAfterFill: $0.autoSubmitAfterFill,
                    submitDelaySeconds: $0.submitDelaySeconds
                )
            },
            selectedPageID: selectedPageID,
            syncSubmitEnabled: isSyncSubmitEnabled,
            autoSubmitBackup: autoSubmitBackup.reduce(into: [String: Bool]()) { result, entry in
                result[entry.key.uuidString] = entry.value
            }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.snapshot)
    }
}
