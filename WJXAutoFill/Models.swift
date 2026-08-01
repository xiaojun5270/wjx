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

final class RuleStore: ObservableObject {
    static let presetCount = 10

    private enum Key {
        static let rules = "fillRules.v1"
        static let presets = "submissionPresets.v2"
        static let selectedPresetID = "selectedPresetID.v2"
        static let surveyURL = "surveyURL.v1"
        static let autoFill = "autoFillOnLoad.v1"
        static let parallelConcurrency = "parallelConcurrency.v2"
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

    @Published private(set) var parallelConcurrency: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        surveyURLString = defaults.string(forKey: Key.surveyURL)
            ?? "https://www.wjx.cn/vm/moYL383.aspx"

        if defaults.object(forKey: Key.autoFill) == nil {
            autoFillOnLoad = true
        } else {
            autoFillOnLoad = defaults.bool(forKey: Key.autoFill)
        }

        // 固定十组任务同时启动；使用新键，避免旧版本保存的 3/5 并发继续生效。
        parallelConcurrency = Self.presetCount

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

        defaults.set(parallelConcurrency, forKey: Key.parallelConcurrency)
        persistPresets()
    }

    var surveyURL: URL? {
        guard let url = URL(string: surveyURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
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
