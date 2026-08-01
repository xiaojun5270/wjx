import Foundation
import Combine

struct FillRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var questionContains: String
    var answer: String
    var isEnabled: Bool = true
}

struct SubmissionPreset: Identifiable, Codable, Hashable {
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
        ["姓名", "工号"].allSatisfy { keyword in
            usableRules.contains { $0.questionContains.contains(keyword) }
        }
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
    private static let defaultEmailDomain = "example.com"
    private static let randomEmailPrefix = "{{random_email:"
    private static let randomEmailSuffix = "}}"

    private enum Key {
        static let rules = "fillRules.v1"
        static let presets = "submissionPresets.v2"
        static let selectedPresetID = "selectedPresetID.v2"
        static let surveyURL = "surveyURL.v1"
        static let autoFill = "autoFillOnLoad.v1"
        static let queueDelay = "queueDelaySeconds.v1"
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

    @Published var queueDelaySeconds: Double {
        didSet { defaults.set(queueDelaySeconds, forKey: Key.queueDelay) }
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

        if defaults.object(forKey: Key.queueDelay) == nil {
            queueDelaySeconds = 2
        } else {
            queueDelaySeconds = max(2, min(defaults.double(forKey: Key.queueDelay), 30))
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
            rawPresets = [
                SubmissionPreset(
                    name: "预设 1",
                    rules: [
                        FillRule(questionContains: "姓名", answer: "", isEnabled: false),
                        FillRule(questionContains: "工号", answer: "", isEnabled: false),
                        FillRule(
                            questionContains: "邮箱",
                            answer: Self.randomEmailToken(domain: Self.defaultEmailDomain),
                            isEnabled: true
                        )
                    ]
                )
            ]
        }
        let loadedPresets = rawPresets.map(Self.normalizedPreset)
        presets = loadedPresets

        if let storedValue = defaults.string(forKey: Key.selectedPresetID),
           let storedID = UUID(uuidString: storedValue),
           loadedPresets.contains(where: { $0.id == storedID }) {
            selectedPresetID = storedID
        } else {
            selectedPresetID = loadedPresets[0].id
        }
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
        Array(presets.filter { $0.isQueueReady }.prefix(20))
    }

    func addPreset(copyCurrent: Bool) {
        let number = presets.count + 1
        let rules = copyCurrent
            ? (selectedPreset?.rules ?? []).map {
                FillRule(
                    questionContains: $0.questionContains,
                    answer: $0.answer,
                    isEnabled: $0.isEnabled
                )
            }
            : []
        let preset = Self.normalizedPreset(SubmissionPreset(name: "预设 \(number)", rules: rules))
        presets.append(preset)
        selectedPresetID = preset.id
    }

    func deleteSelectedPreset() {
        guard presets.count > 1, let index = selectedPresetIndex else { return }
        presets.remove(at: index)
        selectedPresetID = presets[min(index, presets.count - 1)].id
    }

    func addRule(question: String = "", answer: String = "") {
        guard let index = selectedPresetIndex else { return }
        presets[index].rules.append(FillRule(questionContains: question, answer: answer))
    }

    func fixedAnswer(for keyword: String) -> String {
        guard let presetIndex = selectedPresetIndex,
              let ruleIndex = fixedRuleIndex(keyword: keyword, presetIndex: presetIndex) else {
            return ""
        }
        return presets[presetIndex].rules[ruleIndex].answer
    }

    func setFixedAnswer(_ value: String, for keyword: String) {
        guard let presetIndex = selectedPresetIndex else { return }
        let ruleIndex = ensureFixedRule(keyword: keyword, presetIndex: presetIndex)
        presets[presetIndex].rules[ruleIndex].answer = value
        presets[presetIndex].rules[ruleIndex].isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var randomEmailDomain: String {
        guard let presetIndex = selectedPresetIndex,
              let ruleIndex = fixedRuleIndex(keyword: "邮箱", presetIndex: presetIndex) else {
            return Self.defaultEmailDomain
        }
        return Self.randomEmailDomain(from: presets[presetIndex].rules[ruleIndex].answer)
            ?? Self.defaultEmailDomain
    }

    func setRandomEmailDomain(_ domain: String) {
        guard let presetIndex = selectedPresetIndex else { return }
        let ruleIndex = ensureFixedRule(keyword: "邮箱", presetIndex: presetIndex)
        presets[presetIndex].rules[ruleIndex].answer = Self.randomEmailToken(domain: domain)
    }

    func deleteRules(at offsets: IndexSet) {
        guard let presetIndex = selectedPresetIndex else { return }
        for offset in offsets.sorted(by: >) {
            presets[presetIndex].rules.remove(at: offset)
        }
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
        let answer = keyword == "邮箱"
            ? Self.randomEmailToken(domain: Self.defaultEmailDomain)
            : ""
        presets[presetIndex].rules.append(
            FillRule(questionContains: keyword, answer: answer, isEnabled: keyword == "邮箱")
        )
        return presets[presetIndex].rules.count - 1
    }

    private static func normalizedPreset(_ preset: SubmissionPreset) -> SubmissionPreset {
        var result = preset
        result.rules.removeAll {
            !$0.isEnabled &&
            $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            ["部门", "手机"].contains($0.questionContains.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        for keyword in ["姓名", "工号"] where !result.rules.contains(where: { $0.questionContains.contains(keyword) }) {
            result.rules.append(FillRule(questionContains: keyword, answer: "", isEnabled: false))
        }

        if let emailIndex = result.rules.firstIndex(where: { $0.questionContains.contains("邮箱") }) {
            let oldAnswer = result.rules[emailIndex].answer
            let legacyDomain: String?
            if let atIndex = oldAnswer.lastIndex(of: "@") {
                legacyDomain = String(oldAnswer[oldAnswer.index(after: atIndex)...])
            } else {
                legacyDomain = nil
            }
            let domain = randomEmailDomain(from: oldAnswer)
                ?? legacyDomain
                ?? defaultEmailDomain
            result.rules[emailIndex].answer = randomEmailToken(domain: domain)
            result.rules[emailIndex].isEnabled = true
        } else {
            result.rules.append(
                FillRule(
                    questionContains: "邮箱",
                    answer: randomEmailToken(domain: defaultEmailDomain),
                    isEnabled: true
                )
            )
        }
        return result
    }

    private static func randomEmailToken(domain: String) -> String {
        let cleaned = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: " ", with: "")
        return randomEmailPrefix + (cleaned.isEmpty ? defaultEmailDomain : cleaned) + randomEmailSuffix
    }

    private static func randomEmailDomain(from answer: String) -> String? {
        guard answer.hasPrefix(randomEmailPrefix), answer.hasSuffix(randomEmailSuffix) else {
            return nil
        }
        let start = answer.index(answer.startIndex, offsetBy: randomEmailPrefix.count)
        let end = answer.index(answer.endIndex, offsetBy: -randomEmailSuffix.count)
        let domain = String(answer[start..<end])
        return domain.isEmpty ? nil : domain
    }
}
