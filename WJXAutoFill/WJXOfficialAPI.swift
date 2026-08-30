import Foundation
import Security

struct WJXOfficialAPISettings: Codable, Equatable {
    static let defaultValue = WJXOfficialAPISettings(
        isEnabled: false,
        gatewayURLString: "",
        surveyID: "",
        nameQuestionNumber: 1,
        employeeQuestionNumber: 2,
        emailQuestionNumber: 3,
        inputCostTimeSeconds: 2
    )

    var isEnabled: Bool
    var gatewayURLString: String
    var surveyID: String
    var nameQuestionNumber: Int
    var employeeQuestionNumber: Int
    /// 设为 0 时不向 API 提交邮箱题。
    var emailQuestionNumber: Int
    var inputCostTimeSeconds: Int

    func validationMessage(accessToken: String) -> String? {
        guard validatedGatewayURL != nil else {
            return "请输入有效的 HTTPS API 网关地址"
        }
        guard let surveyNumber = Int(surveyID.trimmingCharacters(in: .whitespacesAndNewlines)),
              surveyNumber > 0 else {
            return "请输入问卷星提供的数字问卷编号 vid"
        }
        guard nameQuestionNumber > 0, employeeQuestionNumber > 0 else {
            return "姓名和工号题号必须大于 0"
        }
        guard emailQuestionNumber >= 0 else {
            return "邮箱题号不能小于 0"
        }
        let questionNumbers = [nameQuestionNumber, employeeQuestionNumber] +
            (emailQuestionNumber > 0 ? [emailQuestionNumber] : [])
        guard Set(questionNumbers).count == questionNumbers.count else {
            return "姓名、工号和邮箱题号不能重复"
        }
        guard (2...86_400).contains(inputCostTimeSeconds) else {
            return "API 填写耗时必须在 2 到 86400 秒之间"
        }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请输入 API 网关访问令牌"
        }
        return nil
    }

    func configuration(accessToken: String) throws -> WJXOfficialAPIConfiguration {
        if let message = validationMessage(accessToken: accessToken) {
            throw WJXOfficialAPIError.invalidConfiguration(message)
        }
        guard let gatewayURL = validatedGatewayURL,
              let surveyNumber = Int(surveyID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WJXOfficialAPIError.invalidConfiguration("API 配置无效")
        }
        return WJXOfficialAPIConfiguration(
            gatewayURL: gatewayURL,
            accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            surveyID: surveyNumber,
            nameQuestionNumber: nameQuestionNumber,
            employeeQuestionNumber: employeeQuestionNumber,
            emailQuestionNumber: emailQuestionNumber,
            inputCostTimeSeconds: inputCostTimeSeconds
        )
    }

    private var validatedGatewayURL: URL? {
        let value = gatewayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct WJXOfficialAPIConfiguration {
    let gatewayURL: URL
    let accessToken: String
    let surveyID: Int
    let nameQuestionNumber: Int
    let employeeQuestionNumber: Int
    let emailQuestionNumber: Int
    let inputCostTimeSeconds: Int

    var batchEndpointURL: URL {
        gatewayURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("wjx", isDirectory: true)
            .appendingPathComponent("submit-batch", isDirectory: false)
    }
}

enum WJXOfficialAPIError: LocalizedError {
    case invalidConfiguration(String)
    case invalidPreset(String)
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .invalidPreset(let message):
            return message
        case .invalidResponse:
            return "API 网关没有返回有效的 JSON 数据"
        case .server(let statusCode, let message):
            return "API 网关返回 HTTP \(statusCode)：\(message)"
        }
    }
}

enum WJXAnswerEncoder {
    static func encode(
        preset: SubmissionPreset,
        configuration: WJXOfficialAPIConfiguration
    ) throws -> String {
        let name = preset.answer(for: "姓名")
        let employee = preset.answer(for: "工号")
        let email = preset.answer(for: "邮箱")
        guard !name.isEmpty, !employee.isEmpty else {
            throw WJXOfficialAPIError.invalidPreset("\(preset.name)缺少姓名或工号")
        }

        var answers: [(number: Int, value: String)] = [
            (configuration.nameQuestionNumber, sanitize(name)),
            (configuration.employeeQuestionNumber, sanitize(employee))
        ]
        if configuration.emailQuestionNumber > 0 {
            guard !email.isEmpty else {
                throw WJXOfficialAPIError.invalidPreset("\(preset.name)缺少邮箱")
            }
            answers.append((configuration.emailQuestionNumber, sanitize(email)))
        }
        return answers
            .sorted { $0.number < $1.number }
            .map { "\($0.number)$\($0.value)" }
            .joined(separator: "}")
    }

    private static func sanitize(_ value: String) -> String {
        let replacements = [
            ("$", "ξ"),
            ("}", "｝"),
            ("^", "ˆ"),
            ("|", "¦"),
            ("!", "！"),
            ("<", "＜")
        ]
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (source, destination) in replacements {
            result = result.replacingOccurrences(of: source, with: destination)
        }
        result = result.unicodeScalars
            .filter { scalar in
                scalar.value >= 0x20 || [0x09, 0x0A, 0x0D].contains(scalar.value)
            }
            .map { String(describing: $0) }
            .joined()
        return result
    }
}

struct WJXAPIBatchSummary: Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int

    var message: String {
        "API 批量提交完成：成功 \(succeeded)，失败 \(failed)，共 \(total) 组。"
    }
}

enum WJXAPIBatchState: Equatable {
    case idle
    case submitting(total: Int)
    case completed(WJXAPIBatchSummary)
    case failed(String)
}

final class WJXAPIBatchController: ObservableObject {
    @Published private(set) var state: WJXAPIBatchState = .idle
    @Published private(set) var logs: [AutomationLogEntry] = []

    private var requestTask: Task<Void, Never>?

    deinit {
        requestTask?.cancel()
    }

    var isSubmitting: Bool {
        if case .submitting = state { return true }
        return false
    }

    var logExportText: String {
        logs.map { entry in
            let time = entry.timestamp.formatted(date: .numeric, time: .standard)
            return "[\(time)] [\(entry.category.rawValue)] [\(entry.level.displayName)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    func clearLogs() {
        logs.removeAll()
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        if isSubmitting {
            state = .idle
            appendLog("API 批量提交已取消。", level: .warning)
        }
    }

    func submit(
        presets: [SubmissionPreset],
        settings: WJXOfficialAPISettings,
        accessToken: String,
        completion: @escaping (Result<WJXAPIBatchSummary, Error>) -> Void
    ) {
        guard !isSubmitting else { return }
        do {
            let configuration = try settings.configuration(accessToken: accessToken)
            let payload = try WJXGatewayBatchRequest(
                presets: presets,
                configuration: configuration
            )
            state = .submitting(total: presets.count)
            appendLog(
                "开始通过官方 API 提交 \(presets.count) 组预设；vid=\(configuration.surveyID)。"
            )
            requestTask = Task { @MainActor [weak self] in
                do {
                    let response = try await WJXOfficialAPIClient.submitBatch(
                        payload,
                        configuration: configuration
                    )
                    try Task.checkCancellation()
                    guard response.results.count == presets.count else {
                        throw WJXOfficialAPIError.invalidResponse
                    }
                    let expectedIDs = Set(
                        presets.map { $0.id.uuidString.lowercased() }
                    )
                    let responseIDs = Set(
                        response.results.map { $0.clientID.lowercased() }
                    )
                    guard expectedIDs == responseIDs else {
                        throw WJXOfficialAPIError.invalidResponse
                    }
                    guard let self else { return }
                    let summary = WJXAPIBatchSummary(
                        total: response.results.count,
                        succeeded: response.results.filter(\.success).count,
                        failed: response.results.filter { !$0.success }.count
                    )
                    for result in response.results {
                        self.appendLog(
                            result.success
                                ? "\(result.presetName)通过 API 提交成功。"
                                : "\(result.presetName)通过 API 提交失败：\(result.message ?? "未知错误")",
                            level: result.success ? .success : .error
                        )
                    }
                    self.state = .completed(summary)
                    self.appendLog(
                        summary.message,
                        level: summary.failed == 0 ? .success : .warning
                    )
                    self.requestTask = nil
                    completion(.success(summary))
                } catch is CancellationError {
                    self?.requestTask = nil
                } catch {
                    guard let self else { return }
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    self.appendLog("API 批量提交失败：\(message)", level: .error)
                    self.requestTask = nil
                    completion(.failure(error))
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            appendLog("API 配置检查失败：\(error.localizedDescription)", level: .error)
            completion(.failure(error))
        }
    }

    private func appendLog(
        _ message: String,
        level: AutomationLogLevel = .info
    ) {
        logs.append(
            AutomationLogEntry(
                timestamp: Date(),
                level: level,
                category: .batch,
                message: message
            )
        )
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }
}

private struct WJXGatewayBatchRequest: Encodable {
    struct Submission: Encodable {
        let clientID: String
        let presetName: String
        let submitdata: String
    }

    let vid: Int
    let inputCostTime: Int
    let submissions: [Submission]

    enum CodingKeys: String, CodingKey {
        case vid
        case inputCostTime
        case submissions
    }

    init(
        presets: [SubmissionPreset],
        configuration: WJXOfficialAPIConfiguration
    ) throws {
        guard !presets.isEmpty else {
            throw WJXOfficialAPIError.invalidPreset("没有可提交的预设")
        }
        vid = configuration.surveyID
        inputCostTime = configuration.inputCostTimeSeconds
        submissions = try presets.map { preset in
            Submission(
                clientID: preset.id.uuidString.lowercased(),
                presetName: preset.name,
                submitdata: try WJXAnswerEncoder.encode(
                    preset: preset,
                    configuration: configuration
                )
            )
        }
    }
}

private struct WJXGatewayBatchResponse: Decodable {
    struct SubmissionResult: Decodable {
        let clientID: String
        let presetName: String
        let success: Bool
        let message: String?
    }

    let success: Bool
    let results: [SubmissionResult]
    let message: String?
}

private enum WJXOfficialAPIClient {
    private struct ErrorEnvelope: Decodable {
        let message: String?
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    static func submitBatch(
        _ payload: WJXGatewayBatchRequest,
        configuration: WJXOfficialAPIConfiguration
    ) async throws -> WJXGatewayBatchResponse {
        var request = URLRequest(url: configuration.batchEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(configuration.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WJXOfficialAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let fallback = String(data: data, encoding: .utf8) ?? "未知错误"
            throw WJXOfficialAPIError.server(
                statusCode: httpResponse.statusCode,
                message: envelope?.message ?? fallback
            )
        }
        guard let decoded = try? JSONDecoder().decode(WJXGatewayBatchResponse.self, from: data) else {
            throw WJXOfficialAPIError.invalidResponse
        }
        return decoded
    }
}

enum WJXAPICredentialStore {
    private static let service = "com.example.WJXAutoFill.official-api"
    private static let account = "gateway-access-token"

    static func readAccessToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    static func storeAccessToken(_ value: String) {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if token.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
