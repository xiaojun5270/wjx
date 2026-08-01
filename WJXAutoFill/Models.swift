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

        let loadedPresets: [SubmissionPreset]
        if let data = defaults.data(forKey: Key.presets),
           let decoded = try? JSONDecoder().decode([SubmissionPreset].self, from: data),
           !decoded.isEmpty {
            loadedPresets = decoded
        } else if let oldData = defaults.data(forKey: Key.rules),
                  let oldRules = try? JSONDecoder().decode([FillRule].self, from: oldData),
                  !oldRules.isEmpty {
            loadedPresets = [SubmissionPreset(name: "预设 1", rules: oldRules)]
        } else {
            loadedPresets = [
                SubmissionPreset(
                    name: "预设 1",
                    rules: [
                        FillRule(questionContains: "姓名", answer: "", isEnabled: false),
                        FillRule(questionContains: "工号", answer: "", isEnabled: false),
                        FillRule(questionContains: "部门", answer: "", isEnabled: false),
                        FillRule(questionContains: "手机", answer: "", isEnabled: false)
                    ]
                )
            ]
        }
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
        Array(presets.filter { !$0.usableRules.isEmpty }.prefix(20))
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
        let preset = SubmissionPreset(name: "预设 \(number)", rules: rules)
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
}
