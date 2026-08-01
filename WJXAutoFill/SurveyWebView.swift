import SwiftUI
import UIKit
import WebKit

final class SurveyWebController: ObservableObject {
    @Published var state: SurveyPageState = .loading
    @Published var detectedQuestions: [DetectedQuestion] = []
    @Published var notice: UserNotice?
    @Published private(set) var isSubmitting = false
    @Published private(set) var queueState: TestQueueState = .idle

    fileprivate weak var webView: WKWebView?
    private var queuedPresets: [SubmissionPreset] = []
    private var queueIndex = 0
    private var queueSurveyURL: URL?
    private var queueDelay: TimeInterval = 2
    private var queueSessionID: UUID?
    private var queuePhase: QueuePhase?

    private enum QueuePhase {
        case loadingForm
        case submitting
        case waitingForNext
    }

    private enum FillEvaluation {
        case success(matched: Int, filled: Int)
        case closed(String)
        case failed(String)
    }

    var isQueueRunning: Bool {
        queueSessionID != nil
    }

    var canAttemptSubmit: Bool {
        guard !isSubmitting else { return false }
        if case .ready(_) = state { return true }
        if case .captchaRequired = state { return true }
        return false
    }

    func reload() {
        if !isQueueRunning {
            queueState = .idle
        }
        state = .loading
        webView?.reload()
    }

    func fill(rules: [FillRule], silent: Bool = false) {
        evaluateFill(rules: rules) { [weak self] evaluation in
            guard let self else { return }
            switch evaluation {
            case .success(let matched, let filled):
                if !silent {
                    self.notice = UserNotice(
                        title: filled > 0 ? "自动填写完成" : "没有填入内容",
                        message: "匹配到 \(matched) 条规则，填入或选中 \(filled) 个控件。请核对页面后再提交。"
                    )
                }
            case .closed(let message):
                self.state = .closed(message)
                if !silent {
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                }
            case .failed(let message):
                if !silent {
                    self.notice = UserNotice(title: "自动填写失败", message: message)
                }
            }
        }
    }

    func startTestQueue(presets: [SubmissionPreset], surveyURL: URL, delay: TimeInterval) {
        guard !isQueueRunning else { return }
        guard let webView else {
            notice = UserNotice(title: "无法启动测试", message: "问卷页面尚未加载。")
            return
        }

        let usablePresets = Array(presets.filter { !$0.usableRules.isEmpty }.prefix(20))
        guard usablePresets.count >= 2 else {
            notice = UserNotice(title: "预设不足", message: "连续测试至少需要两个含有效填写规则的预设。")
            return
        }

        queuedPresets = usablePresets
        queueIndex = 0
        queueSurveyURL = surveyURL
        queueDelay = max(2, min(delay, 30))
        queueSessionID = UUID()
        queuePhase = .loadingForm
        queueState = .running(current: 1, total: usablePresets.count, presetName: usablePresets[0].name)
        state = .loading
        webView.load(URLRequest(url: surveyURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }

    func stopTestQueue() {
        guard isQueueRunning else { return }
        stopQueue(message: "测试队列已由用户停止。", showNotice: true)
    }

    func submitOnce() {
        guard !isSubmitting else { return }
        guard let webView else {
            notice = UserNotice(title: "提交失败", message: "问卷页面尚未加载。")
            return
        }
        isSubmitting = true
        webView.evaluateJavaScript(AutomationScript.submit) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.isSubmitting = false
                    self.notice = UserNotice(title: "提交失败", message: error.localizedDescription)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      let status = payload["status"] as? String else {
                    self.isSubmitting = false
                    self.notice = UserNotice(title: "提交失败", message: "页面没有返回有效状态。")
                    return
                }
                switch status {
                case "scheduled":
                    self.notice = UserNotice(title: "已触发单次提交", message: "请留意页面返回结果；如果出现验证码，请在页面中手动完成。")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if self.webView?.isLoading == false {
                            self.scanPage()
                        }
                    }
                case "captcha":
                    self.isSubmitting = false
                    self.state = .captchaRequired
                    self.notice = UserNotice(title: "需要人机验证", message: "应用不会绕过验证码，请先在问卷页面中手动完成验证。")
                case "closed":
                    self.isSubmitting = false
                    let message = payload["message"] as? String ?? "问卷当前不可提交。"
                    self.state = .closed(message)
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                default:
                    self.isSubmitting = false
                    self.notice = UserNotice(
                        title: "无法提交",
                        message: payload["message"] as? String ?? "当前页面没有可用的提交按钮。"
                    )
                }
            }
        }
    }

    fileprivate func handlePageLoaded(defaultRules: [FillRule], autoFillOnLoad: Bool) {
        scanPage { [weak self] scannedState in
            guard let self else { return }
            if self.isQueueRunning {
                self.handleQueuePage(state: scannedState)
            } else if autoFillOnLoad, case .ready(_) = scannedState {
                self.fill(rules: defaultRules, silent: true)
            }
        }
    }

    fileprivate func handleNavigationFailure(_ error: Error) {
        let message = error.localizedDescription
        state = .failed(message)
        if isQueueRunning {
            stopQueue(message: "页面加载失败：\(message)", showNotice: true)
        }
    }

    fileprivate func scanPage(completion: ((SurveyPageState) -> Void)? = nil) {
        webView?.evaluateJavaScript(AutomationScript.scan) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.isSubmitting = false
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

    private func handleQueuePage(state: SurveyPageState) {
        guard isQueueRunning, let phase = queuePhase else { return }

        switch phase {
        case .loadingForm:
            guard case .ready(let questionCount) = state, questionCount > 0 else {
                stopQueueForPageState(state, fallback: "没有检测到可填写题目。")
                return
            }
            let preset = queuedPresets[queueIndex]
            evaluateFill(rules: preset.usableRules) { [weak self] evaluation in
                guard let self, self.isQueueRunning else { return }
                switch evaluation {
                case .success(let matched, let filled):
                    guard matched > 0, filled > 0 else {
                        self.stopQueue(message: "预设“\(preset.name)”没有匹配到可填写控件。", showNotice: true)
                        return
                    }
                    let sessionID = self.queueSessionID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard self.queueSessionID == sessionID else { return }
                        self.submitCurrentQueuePreset()
                    }
                case .closed(let message):
                    self.stopQueue(message: message, showNotice: true)
                case .failed(let message):
                    self.stopQueue(message: "预设“\(preset.name)”填写失败：\(message)", showNotice: true)
                }
            }

        case .submitting:
            switch state {
            case .submitted(_):
                advanceQueue()
            case .captchaRequired:
                stopQueue(message: "页面要求人机验证，测试队列已停止。", showNotice: true)
            case .closed(let message), .failed(let message):
                stopQueue(message: message, showNotice: true)
            case .ready(_):
                stopQueue(message: "提交后仍停留在问卷页面，可能有必填项或格式校验未通过。", showNotice: true)
            case .loading:
                break
            }

        case .waitingForNext:
            break
        }
    }

    private func submitCurrentQueuePreset() {
        guard isQueueRunning, let webView else { return }
        isSubmitting = true
        webView.evaluateJavaScript(AutomationScript.submit) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isQueueRunning else { return }
                if let error {
                    self.isSubmitting = false
                    self.stopQueue(message: "提交失败：\(error.localizedDescription)", showNotice: true)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      let status = payload["status"] as? String else {
                    self.isSubmitting = false
                    self.stopQueue(message: "页面没有返回有效提交状态。", showNotice: true)
                    return
                }
                switch status {
                case "scheduled":
                    self.queuePhase = .submitting
                    let sessionID = self.queueSessionID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard self.queueSessionID == sessionID,
                              self.webView?.isLoading == false else { return }
                        self.scanPage { [weak self] scannedState in
                            self?.handleQueuePage(state: scannedState)
                        }
                    }
                case "captcha":
                    self.isSubmitting = false
                    self.stopQueue(message: "页面要求人机验证，测试队列已停止。", showNotice: true)
                case "closed":
                    self.isSubmitting = false
                    self.stopQueue(
                        message: payload["message"] as? String ?? "问卷当前不可提交。",
                        showNotice: true
                    )
                default:
                    self.isSubmitting = false
                    self.stopQueue(
                        message: payload["message"] as? String ?? "当前页面没有可用提交按钮。",
                        showNotice: true
                    )
                }
            }
        }
    }

    private func advanceQueue() {
        guard isQueueRunning else { return }
        let nextIndex = queueIndex + 1
        guard nextIndex < queuedPresets.count else {
            let total = queuedPresets.count
            clearQueueSession()
            queueState = .completed(total: total)
            notice = UserNotice(title: "连续测试完成", message: "已按顺序完成 \(total) 个预设。")
            return
        }

        queueIndex = nextIndex
        queuePhase = .waitingForNext
        let nextPreset = queuedPresets[nextIndex]
        queueState = .running(
            current: nextIndex + 1,
            total: queuedPresets.count,
            presetName: nextPreset.name
        )

        let sessionID = queueSessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + queueDelay) { [weak self] in
            guard let self,
                  self.queueSessionID == sessionID,
                  let url = self.queueSurveyURL,
                  let webView = self.webView else { return }
            self.queuePhase = .loadingForm
            self.state = .loading
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
    }

    private func stopQueueForPageState(_ state: SurveyPageState, fallback: String) {
        switch state {
        case .closed(let message), .failed(let message):
            stopQueue(message: message, showNotice: true)
        case .captchaRequired:
            stopQueue(message: "页面要求人机验证，测试队列已停止。", showNotice: true)
        case .submitted(_):
            stopQueue(message: "加载测试表单时进入了提交完成页。", showNotice: true)
        default:
            stopQueue(message: fallback, showNotice: true)
        }
    }

    private func stopQueue(message: String, showNotice: Bool) {
        clearQueueSession()
        queueState = .stopped(message)
        if showNotice {
            notice = UserNotice(title: "连续测试已停止", message: message)
        }
    }

    private func clearQueueSession() {
        queueSessionID = nil
        queuePhase = nil
        queuedPresets = []
        queueIndex = 0
        queueSurveyURL = nil
        isSubmitting = false
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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        controller.webView = webView
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = webView
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            controller.state = .loading
            webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SurveyWebView
        var loadedURL: URL?

        init(parent: SurveyWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.controller.state = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.controller.handlePageLoaded(
                defaultRules: parent.rules,
                autoFillOnLoad: parent.autoFillOnLoad
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.controller.handleNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
    }
}
