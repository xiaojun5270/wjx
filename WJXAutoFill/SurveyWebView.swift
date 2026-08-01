import SwiftUI
import UIKit
import WebKit

final class SurveyWebController: ObservableObject {
    @Published var state: SurveyPageState = .loading
    @Published var detectedQuestions: [DetectedQuestion] = []
    @Published var notice: UserNotice?
    @Published private(set) var isFilling = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var queueState: TestQueueState = .idle
    @Published private(set) var canGoBack = false
    @Published private(set) var logs: [AutomationLogEntry] = []

    fileprivate weak var webView: WKWebView?
    private var queuedPresets: [SubmissionPreset] = []
    private var queueSessionID: UUID?
    private var parallelRunID: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var hasAutoSubmittedCurrentForm = false

    private enum FillEvaluation {
        case success(matched: Int, filled: Int)
        case closed(String)
        case failed(String)
    }

    var isQueueRunning: Bool {
        queueSessionID != nil
    }

    var canAttemptSubmit: Bool {
        guard !isFilling, !isSubmitting else { return false }
        if case .ready(_) = state { return true }
        if case .captchaRequired = state { return true }
        return false
    }

    func clearLogs() {
        logs.removeAll()
    }

    func reload() {
        if !isQueueRunning {
            queueState = .idle
        }
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("重新加载问卷页面。")
        webView?.reload()
    }

    func goBack() {
        guard !isQueueRunning, !isFilling, !isSubmitting,
              let webView, webView.canGoBack else { return }
        hasAutoSubmittedCurrentForm = false
        state = .loading
        appendLog("返回上一页。")
        webView.goBack()
    }

    func fill(rules: [FillRule], silent: Bool = false) {
        guard !isFilling, !isSubmitting else { return }
        isFilling = true
        appendLog("开始自动填写。")
        evaluateFill(rules: rules) { [weak self] evaluation in
            guard let self else { return }
            self.isFilling = false
            switch evaluation {
            case .success(let matched, let filled):
                self.appendLog(
                    "自动填写完成：匹配 \(matched) 条规则，填写 \(filled) 个控件。",
                    level: filled > 0 ? .success : .warning
                )
                if !silent {
                    self.notice = UserNotice(
                        title: filled > 0 ? "自动填写完成" : "没有填入内容",
                        message: "匹配到 \(matched) 条规则，填入或选中 \(filled) 个控件。请核对页面后再提交。"
                    )
                }
            case .closed(let message):
                self.state = .closed(message)
                self.appendLog("问卷不可填写：\(message)", level: .warning)
                if !silent {
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                }
            case .failed(let message):
                self.appendLog("自动填写失败：\(message)", level: .error)
                if !silent {
                    self.notice = UserNotice(title: "自动填写失败", message: message)
                }
            }
        }
    }

    func fillAndSubmit(rules: [FillRule], silent: Bool = false) {
        guard !isFilling, !isSubmitting else { return }
        isFilling = true
        hasAutoSubmittedCurrentForm = true
        appendLog("开始自动填写，完成后将自动提交。")
        evaluateFill(rules: rules) { [weak self] evaluation in
            guard let self else { return }
            self.isFilling = false
            switch evaluation {
            case .success(let matched, let filled):
                self.appendLog(
                    "自动填写完成：匹配 \(matched) 条规则，填写 \(filled) 个控件。",
                    level: filled > 0 ? .success : .warning
                )
                guard filled > 0 else {
                    if !silent {
                        self.notice = UserNotice(title: "没有填入内容", message: "页面没有匹配到可填写控件，因此未提交。")
                    }
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard !self.isQueueRunning else { return }
                    self.submitOnce(showScheduledNotice: !silent, source: "自动提交")
                }

            case .closed(let message):
                self.state = .closed(message)
                self.appendLog("问卷不可填写：\(message)", level: .warning)
                if !silent {
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                }

            case .failed(let message):
                self.appendLog("自动填写失败：\(message)", level: .error)
                if !silent {
                    self.notice = UserNotice(title: "自动填写失败", message: message)
                }
            }
        }
    }

    func startParallelTest(
        presets: [SubmissionPreset],
        surveyURL: URL,
        concurrency: Int
    ) {
        guard !isQueueRunning, !isFilling, !isSubmitting else { return }
        guard let webView else {
            appendLog("并行提交启动失败：问卷页面尚未加载。", level: .error)
            notice = UserNotice(title: "无法启动测试", message: "问卷页面尚未加载。")
            return
        }

        let usablePresets = Array(presets.filter { $0.isQueueReady }.prefix(RuleStore.presetCount))
        guard usablePresets.count == RuleStore.presetCount else {
            appendLog("并行提交启动失败：10 组预设未填写完整。", level: .warning)
            notice = UserNotice(title: "预设未填写完整", message: "请先完整填写 10 组不同的姓名、工号和固定邮箱。")
            return
        }

        for keyword in SubmissionPreset.requiredQuestions {
            let values = usablePresets.map { $0.answer(for: keyword).lowercased() }
            guard Set(values).count == RuleStore.presetCount else {
                appendLog("并行提交启动失败：10 组预设的\(keyword)存在重复。", level: .warning)
                notice = UserNotice(title: "预设内容重复", message: "10 组预设的\(keyword)必须各不相同。")
                return
            }
        }

        let sessionID = UUID()
        let runID = sessionID.uuidString
        guard let script = AutomationScript.parallelFill(
            presets: usablePresets,
            surveyURL: surveyURL,
            concurrency: concurrency,
            runID: runID
        ) else {
            appendLog("并行提交启动失败：无法生成后台任务。", level: .error)
            notice = UserNotice(title: "无法启动测试", message: "生成后台任务失败。")
            return
        }

        queuedPresets = usablePresets
        queueSessionID = sessionID
        parallelRunID = runID
        queueState = .running(current: 0, total: usablePresets.count, presetName: "正在启动后台任务")
        appendLog("启动 \(usablePresets.count) 个并行填写和提交任务。")
        beginBackgroundExecution()

        webView.evaluateJavaScript(script) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.parallelRunID == runID else { return }
                if let error {
                    self.stopQueue(message: "启动后台任务失败：\(error.localizedDescription)", showNotice: true)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      payload["status"] as? String == "started" else {
                    self.stopQueue(message: "后台任务没有成功启动。", showNotice: true)
                    return
                }
            }
        }
    }

    func stopTestQueue() {
        guard isQueueRunning else { return }
        if let runID = parallelRunID,
           let script = AutomationScript.cancelParallel(runID: runID) {
            webView?.evaluateJavaScript(script)
        }
        stopQueue(message: "后台并行测试已由用户停止。", showNotice: true)
    }

    func submitOnce(showScheduledNotice: Bool = true, source: String = "手动提交") {
        guard !isFilling, !isSubmitting else { return }
        guard let webView else {
            appendLog("\(source)失败：问卷页面尚未加载。", level: .error)
            notice = UserNotice(title: "提交失败", message: "问卷页面尚未加载。")
            return
        }
        appendLog("正在执行\(source)。")
        isSubmitting = true
        webView.evaluateJavaScript(AutomationScript.submit) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.isSubmitting = false
                    self.appendLog("\(source)失败：\(error.localizedDescription)", level: .error)
                    self.notice = UserNotice(title: "提交失败", message: error.localizedDescription)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      let status = payload["status"] as? String else {
                    self.isSubmitting = false
                    self.appendLog("\(source)失败：页面没有返回有效状态。", level: .error)
                    self.notice = UserNotice(title: "提交失败", message: "页面没有返回有效状态。")
                    return
                }
                switch status {
                case "scheduled":
                    self.appendLog("已触发\(source)，正在等待页面结果。")
                    if showScheduledNotice {
                        self.notice = UserNotice(title: "已触发提交", message: "请留意页面返回结果；如果出现验证码，请在页面中手动完成。")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.webView?.isLoading == false {
                            self.scanPage { [weak self] state in
                                guard let self else { return }
                                switch state {
                                case .ready(_):
                                    self.appendLog("\(source)未完成：页面仍停留在问卷，可能存在必填项或格式错误。", level: .warning)
                                    self.notice = UserNotice(
                                        title: "提交未完成",
                                        message: "页面仍停留在问卷，请检查必填项和格式提示。"
                                    )
                                case .captchaRequired:
                                    self.notice = UserNotice(
                                        title: "需要人机验证",
                                        message: "请先在问卷页面中手动完成验证。"
                                    )
                                case .failed(let message):
                                    self.notice = UserNotice(title: "提交结果检查失败", message: message)
                                default:
                                    break
                                }
                            }
                        }
                    }
                case "captcha":
                    self.isSubmitting = false
                    self.state = .captchaRequired
                    self.appendLog("\(source)暂停：页面要求人机验证。", level: .warning)
                    self.notice = UserNotice(title: "需要人机验证", message: "应用不会绕过验证码，请先在问卷页面中手动完成验证。")
                case "closed":
                    self.isSubmitting = false
                    let message = payload["message"] as? String ?? "问卷当前不可提交。"
                    self.state = .closed(message)
                    self.appendLog("\(source)失败：\(message)", level: .warning)
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                default:
                    self.isSubmitting = false
                    let message = payload["message"] as? String ?? "当前页面没有可用的提交按钮。"
                    self.appendLog("\(source)失败：\(message)", level: .error)
                    self.notice = UserNotice(
                        title: "无法提交",
                        message: message
                    )
                }
            }
        }
    }

    fileprivate func prepareForNewSurvey(_ url: URL) {
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("打开问卷：\(url.absoluteString)")
    }

    fileprivate func handleNavigationStarted(in webView: WKWebView) {
        state = .loading
        canGoBack = false
        if let url = webView.url {
            appendLog("正在加载页面：\(url.absoluteString)")
        }
    }

    fileprivate func updateNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
    }

    fileprivate func handlePageLoaded(
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool
    ) {
        if let webView {
            updateNavigationState(from: webView)
        }
        scanPage { [weak self] scannedState in
            guard let self else { return }
            if !self.isQueueRunning, autoFillOnLoad, case .ready(_) = scannedState {
                if autoSubmitAfterFill {
                    guard !self.hasAutoSubmittedCurrentForm else { return }
                    self.fillAndSubmit(rules: defaultRules, silent: true)
                } else {
                    self.fill(rules: defaultRules, silent: true)
                }
            }
        }
    }

    fileprivate func handleNavigationFailure(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        appendLog("页面加载失败：\(message)", level: .error)
        if isQueueRunning {
            stopQueue(message: "页面加载失败：\(message)", showNotice: true)
        }
    }

    fileprivate func handleParallelMessage(_ body: Any) {
        guard let payload = body as? [String: Any],
              let runID = payload["runID"] as? String,
              runID == parallelRunID,
              let type = payload["type"] as? String else {
            return
        }

        let completed = payload["completed"] as? Int ?? 0
        let succeeded = payload["succeeded"] as? Int ?? 0
        let failed = payload["failed"] as? Int ?? 0
        let active = payload["active"] as? Int ?? 0
        let total = payload["total"] as? Int ?? queuedPresets.count
        let presetName = payload["presetName"] as? String ?? "当前预设"
        let taskError = payload["error"] as? String ?? ""

        switch type {
        case "started":
            queueState = .running(current: completed, total: total, presetName: "正在调度后台任务")
            appendLog("并行任务已启动：共 \(total) 个。")

        case "progress":
            let detail = active > 0 ? "并行运行 \(active) 个任务" : "正在调度任务"
            queueState = .running(current: completed, total: total, presetName: detail)
            if taskError.isEmpty {
                appendLog("\(presetName)提交完成；总进度 \(completed)/\(total)。", level: .success)
            } else {
                appendLog("\(presetName)提交失败：\(taskError)", level: .error)
            }

        case "complete":
            clearQueueSession()
            queueState = .completed(total: succeeded)
            appendLog("并行提交完成：成功 \(succeeded)，失败 \(failed)。", level: failed == 0 ? .success : .warning)
            notice = UserNotice(
                title: "后台并行测试完成",
                message: "成功 \(succeeded) 个，失败 \(failed) 个，共处理 \(total) 个预设。"
            )

        case "fatal":
            stopQueue(
                message: payload["message"] as? String ?? "后台并行测试已停止。",
                showNotice: true
            )

        case "stopped":
            stopQueue(message: "后台并行测试已停止。", showNotice: false)

        default:
            break
        }
    }

    fileprivate func scanPage(completion: ((SurveyPageState) -> Void)? = nil) {
        webView?.evaluateJavaScript(AutomationScript.scan) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let previousState = self.state
                defer {
                    self.isSubmitting = false
                    if self.state != previousState {
                        self.logPageState(self.state)
                    }
                    completion?(self.state)
                }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      let status = payload["status"] as? String else {
                    self.state = .failed("无法识别问卷页面。")
                    return
                }

                let rawQuestions = payload["questions"] as? [[String: Any]] ?? []
                self.detectedQuestions = rawQuestions.compactMap { item in
                    guard let text = item["text"] as? String else { return nil }
                    return DetectedQuestion(text: text, kind: item["kind"] as? String ?? "题目")
                }

                switch status {
                case "submitted":
                    self.state = .submitted(payload["message"] as? String ?? "提交成功。")
                case "closed":
                    self.state = .closed(payload["message"] as? String ?? "问卷当前不可填写。")
                case "captcha":
                    self.state = .captchaRequired
                default:
                    self.state = .ready(questionCount: self.detectedQuestions.count)
                }
            }
        }
    }

    private func evaluateFill(rules: [FillRule], completion: @escaping (FillEvaluation) -> Void) {
        let usableRules = rules.filter {
            $0.isEnabled &&
            !$0.questionContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usableRules.isEmpty else {
            completion(.failed("没有可用规则，请先填写并启用题目规则。"))
            return
        }
        guard let webView else {
            completion(.failed("问卷页面尚未加载。"))
            return
        }
        guard let script = AutomationScript.fill(rules: usableRules) else {
            completion(.failed("规则编码失败，请检查规则内容。"))
            return
        }

        webView.evaluateJavaScript(script) { result, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failed(error.localizedDescription))
                    return
                }
                guard let payload = Self.dictionary(from: result) else {
                    completion(.failed("页面没有返回有效的填写结果。"))
                    return
                }
                if payload["status"] as? String == "closed" {
                    completion(.closed(payload["message"] as? String ?? "问卷当前不可填写。"))
                    return
                }
                completion(.success(
                    matched: payload["matched"] as? Int ?? 0,
                    filled: payload["filled"] as? Int ?? 0
                ))
            }
        }
    }

    private func stopQueue(message: String, showNotice: Bool) {
        clearQueueSession()
        queueState = .stopped(message)
        appendLog(message, level: .warning)
        if showNotice {
            notice = UserNotice(title: "后台并行测试已停止", message: message)
        }
    }

    private func clearQueueSession() {
        queueSessionID = nil
        queuedPresets = []
        parallelRunID = nil
        isSubmitting = false
        endBackgroundExecution()
    }

    private func beginBackgroundExecution() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WJXParallelTest") { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isQueueRunning else { return }
                self.stopQueue(message: "iOS 后台执行时间已到，测试任务已停止。", showNotice: true)
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func appendLog(_ message: String, level: AutomationLogLevel = .info) {
        logs.append(AutomationLogEntry(timestamp: Date(), level: level, message: message))
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func logPageState(_ state: SurveyPageState) {
        switch state {
        case .loading:
            break
        case .ready(let questionCount):
            appendLog("页面已就绪，检测到 \(questionCount) 道题。")
        case .submitted(let message):
            appendLog("提交成功：\(message)", level: .success)
        case .closed(let message):
            appendLog("问卷不可填写：\(message)", level: .warning)
        case .captchaRequired:
            appendLog("页面要求人机验证。", level: .warning)
        case .failed(let message):
            appendLog("页面处理失败：\(message)", level: .error)
        }
    }

    private static func dictionary(from result: Any?) -> [String: Any]? {
        if let dictionary = result as? [String: Any] { return dictionary }
        guard let string = result as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }
}

struct SurveyWebView: UIViewRepresentable {
    let controller: SurveyWebController
    let url: URL
    let rules: [FillRule]
    let autoFillOnLoad: Bool
    let autoSubmitAfterFill: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "parallelTest")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        controller.webView = webView
        context.coordinator.loadedURL = url
        controller.prepareForNewSurvey(url)
        webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = webView
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            controller.prepareForNewSurvey(url)
            webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "parallelTest")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: SurveyWebView
        var loadedURL: URL?

        init(parent: SurveyWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.controller.handleNavigationStarted(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.controller.handlePageLoaded(
                defaultRules: parent.rules,
                autoFillOnLoad: parent.autoFillOnLoad,
                autoSubmitAfterFill: parent.autoSubmitAfterFill
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.controller.updateNavigationState(from: webView)
            parent.controller.handleNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.controller.updateNavigationState(from: webView)
            parent.controller.handleNavigationFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  let url = navigationAction.request.url,
                  let host = url.host?.lowercased() else {
                decisionHandler(.allow)
                return
            }

            let isAllowed = host == "wjx.cn" || host.hasSuffix(".wjx.cn")
            if isAllowed {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "parallelTest" else { return }
            parent.controller.handleParallelMessage(message.body)
        }
    }
}
