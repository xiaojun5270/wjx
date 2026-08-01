import Foundation
import SwiftUI
import UIKit
import WebKit

final class SurveyWebController: ObservableObject {
    @Published var state: SurveyPageState = .loading
    @Published var detectedQuestions: [DetectedQuestion] = []
    @Published var notice: UserNotice?
    @Published private(set) var isFilling = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isWaitingToSubmit = false
    @Published private(set) var queueState: TestQueueState = .idle
    @Published private(set) var queueSnapshot = ParallelRunSnapshot()
    @Published private(set) var batchPreparedCount = 0
    @Published private(set) var isBatchReadyToSubmit = false
    @Published private(set) var isBatchSubmitting = false
    @Published private(set) var scheduledBatchTarget: Date?
    @Published private(set) var batchScheduleRemainingSeconds = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var logs: [AutomationLogEntry] = []

    fileprivate weak var webView: WKWebView?
    private var queuedPresets: [SubmissionPreset] = []
    private var queueSessionID: UUID?
    private var parallelRunID: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var hasAutoSubmittedCurrentForm = false
    private var pendingAutoSubmitWorkItem: DispatchWorkItem?
    private var scheduledBatch: (presets: [SubmissionPreset], surveyURL: URL)?
    private var pendingScheduledBatch: (presets: [SubmissionPreset], surveyURL: URL)?
    private var batchScheduleWorkItem: DispatchWorkItem?
    private var batchScheduleTimer: Timer?

    private enum FillEvaluation {
        case success(matched: Int, filled: Int)
        case closed(String)
        case failed(String)
    }

    deinit {
        batchScheduleWorkItem?.cancel()
        batchScheduleTimer?.invalidate()
    }

    var isQueueRunning: Bool {
        queueSessionID != nil
    }

    var isScheduledBatchRefreshing: Bool {
        pendingScheduledBatch != nil
    }

    var isBusy: Bool {
        isFilling || isWaitingToSubmit || isSubmitting || isQueueRunning ||
            scheduledBatchTarget != nil || pendingScheduledBatch != nil
    }

    var canAttemptFill: Bool {
        guard !isBusy else { return false }
        if case .ready(_) = state { return true }
        return false
    }

    var canAttemptSubmit: Bool {
        guard !isBusy else { return false }
        if case .ready(_) = state { return true }
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

    func reload() {
        cancelPendingAutoSubmit()
        if !isQueueRunning {
            queueState = .idle
        }
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("重新加载问卷页面。", category: .page)
        webView?.reload()
    }

    func goBack() {
        guard !isBusy,
              let webView, webView.canGoBack else { return }
        cancelPendingAutoSubmit()
        hasAutoSubmittedCurrentForm = false
        state = .loading
        appendLog("返回上一页。", category: .page)
        webView.goBack()
    }

    func fill(rules: [FillRule], silent: Bool = false) {
        guard canAttemptFill else { return }
        resetQueueSummary()
        isFilling = true
        appendLog("开始自动填写。", category: .fill)
        evaluateFill(rules: rules) { [weak self] evaluation in
            guard let self else { return }
            self.isFilling = false
            switch evaluation {
            case .success(let matched, let filled):
                self.appendLog(
                    "自动填写完成：匹配 \(matched) 条规则，填写 \(filled) 个控件。",
                    level: filled > 0 ? .success : .warning,
                    category: .fill
                )
                if !silent {
                    self.notice = UserNotice(
                        title: filled > 0 ? "自动填写完成" : "没有填入内容",
                        message: "匹配到 \(matched) 条规则，填入或选中 \(filled) 个控件。请核对页面后再提交。"
                    )
                }
            case .closed(let message):
                self.state = .closed(message)
                self.appendLog("问卷不可填写：\(message)", level: .warning, category: .fill)
                if !silent {
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                }
            case .failed(let message):
                self.appendLog("自动填写失败：\(message)", level: .error, category: .fill)
                if !silent {
                    self.notice = UserNotice(title: "自动填写失败", message: message)
                }
            }
        }
    }

    func fillAndSubmit(
        rules: [FillRule],
        submitDelaySeconds: Int,
        silent: Bool = false
    ) {
        guard canAttemptFill else { return }
        resetQueueSummary()
        isFilling = true
        hasAutoSubmittedCurrentForm = true
        appendLog("开始自动填写，完成后将自动提交。", category: .fill)
        evaluateFill(rules: rules) { [weak self] evaluation in
            guard let self else { return }
            self.isFilling = false
            switch evaluation {
            case .success(let matched, let filled):
                self.appendLog(
                    "自动填写完成：匹配 \(matched) 条规则，填写 \(filled) 个控件。",
                    level: filled > 0 ? .success : .warning,
                    category: .fill
                )
                guard filled > 0 else {
                    if !silent {
                        self.notice = UserNotice(title: "没有填入内容", message: "页面没有匹配到可填写控件，因此未提交。")
                    }
                    return
                }

                self.scheduleAutoSubmit(
                    showScheduledNotice: !silent,
                    delaySeconds: submitDelaySeconds
                )

            case .closed(let message):
                self.state = .closed(message)
                self.appendLog("问卷不可填写：\(message)", level: .warning, category: .fill)
                if !silent {
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                }

            case .failed(let message):
                self.appendLog("自动填写失败：\(message)", level: .error, category: .fill)
                if !silent {
                    self.notice = UserNotice(title: "自动填写失败", message: message)
                }
            }
        }
    }

    func startParallelTest(
        presets: [SubmissionPreset],
        surveyURL: URL
    ) {
        guard !isBusy else { return }
        guard let webView else {
            appendLog("同步填写启动失败：问卷页面尚未加载。", level: .error, category: .batch)
            notice = UserNotice(title: "无法开始同步填写", message: "问卷页面尚未加载。")
            return
        }

        guard let usablePresets = validatedBatchPresets(presets, action: "同步填写") else { return }

        let sessionID = UUID()
        let runID = sessionID.uuidString
        guard let script = AutomationScript.parallelFill(
            presets: usablePresets,
            surveyURL: surveyURL,
            runID: runID
        ) else {
            appendLog("同步填写启动失败：无法生成后台任务。", level: .error, category: .batch)
            notice = UserNotice(title: "无法开始同步填写", message: "生成后台任务失败。")
            return
        }

        queuedPresets = usablePresets
        queueSessionID = sessionID
        parallelRunID = runID
        batchPreparedCount = 0
        isBatchReadyToSubmit = false
        isBatchSubmitting = false
        queueState = .running(current: 0, total: usablePresets.count, presetName: "正在启动后台任务")
        queueSnapshot = ParallelRunSnapshot(
            completed: 0,
            total: usablePresets.count,
            succeeded: 0,
            failed: 0,
            active: 0,
            detail: "正在启动后台任务"
        )
        appendLog("启动 \(usablePresets.count) 组同步填写任务；填写完成后等待手动提交。", category: .batch)
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

    func scheduleBatchAtNextHour(presets: [SubmissionPreset], surveyURL: URL) {
        guard !isBusy else { return }
        guard webView != nil else {
            appendLog("整点任务设置失败：问卷页面尚未加载。", level: .error, category: .batch)
            notice = UserNotice(title: "无法设置整点任务", message: "问卷页面尚未加载。")
            return
        }
        guard let usablePresets = validatedBatchPresets(presets, action: "整点任务") else { return }

        let now = Date()
        let calendar = Calendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let target = calendar.date(byAdding: .hour, value: 1, to: hourStart)
            ?? now.addingTimeInterval(3_600)

        cancelScheduledBatch(logCancellation: false)
        resetQueueSummary()
        scheduledBatch = (usablePresets, surveyURL)
        scheduledBatchTarget = target
        updateBatchScheduleCountdown()

        let workItem = DispatchWorkItem { [weak self] in
            self?.fireScheduledBatch()
        }
        batchScheduleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(target.timeIntervalSinceNow, 0),
            execute: workItem
        )

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateBatchScheduleCountdown()
        }
        batchScheduleTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        appendLog("整点任务已设置：\(target.formatted(date: .abbreviated, time: .standard))。", category: .batch)
    }

    func cancelScheduledBatch() {
        cancelScheduledBatch(logCancellation: true)
    }

    func submitPreparedBatch() {
        guard isQueueRunning, isBatchReadyToSubmit, !isBatchSubmitting else { return }
        guard let webView,
              let runID = parallelRunID,
              let script = AutomationScript.submitPreparedParallel(runID: runID) else {
            stopQueue(message: "已填写页面不可用，无法开始同步提交。", showNotice: true)
            return
        }

        isBatchReadyToSubmit = false
        isBatchSubmitting = true
        appendLog("已手动确认，正在同时触发 10 组提交。", category: .batch)
        webView.evaluateJavaScript(script) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.parallelRunID == runID else { return }
                if let error {
                    self.stopQueue(message: "同步提交启动失败：\(error.localizedDescription)", showNotice: true)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      payload["status"] as? String == "submitting" else {
                    self.stopQueue(message: "同步提交没有成功启动，已填写页面可能已经失效。", showNotice: true)
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
        stopQueue(message: "批量任务已由用户停止。", showNotice: true)
    }

    func submitOnce(showScheduledNotice: Bool = true, source: String = "手动提交") {
        guard !isBusy else { return }
        resetQueueSummary()
        guard let webView else {
            appendLog("\(source)失败：问卷页面尚未加载。", level: .error, category: .submit)
            notice = UserNotice(title: "提交失败", message: "问卷页面尚未加载。")
            return
        }
        appendLog("正在执行\(source)。", category: .submit)
        isSubmitting = true
        webView.evaluateJavaScript(AutomationScript.submit) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.isSubmitting = false
                    self.appendLog("\(source)失败：\(error.localizedDescription)", level: .error, category: .submit)
                    self.notice = UserNotice(title: "提交失败", message: error.localizedDescription)
                    return
                }
                guard let payload = Self.dictionary(from: result),
                      let status = payload["status"] as? String else {
                    self.isSubmitting = false
                    self.appendLog("\(source)失败：页面没有返回有效状态。", level: .error, category: .submit)
                    self.notice = UserNotice(title: "提交失败", message: "页面没有返回有效状态。")
                    return
                }
                switch status {
                case "scheduled":
                    self.appendLog("已触发\(source)，正在等待页面结果。", category: .submit)
                    if showScheduledNotice {
                        self.notice = UserNotice(title: "已触发提交", message: "请留意页面返回结果；如果出现验证码，请在页面中手动完成。")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.inspectSingleSubmitResult(source: source, attempt: 1)
                    }
                case "captcha":
                    self.isSubmitting = false
                    self.state = .captchaRequired
                    self.appendLog("\(source)暂停：页面要求人机验证。", level: .warning, category: .security)
                    self.notice = UserNotice(title: "需要人机验证", message: "应用不会绕过验证码，请先在问卷页面中手动完成验证。")
                case "closed":
                    self.isSubmitting = false
                    let message = payload["message"] as? String ?? "问卷当前不可提交。"
                    self.state = .closed(message)
                    self.appendLog("\(source)失败：\(message)", level: .warning, category: .submit)
                    self.notice = UserNotice(title: "问卷不可提交", message: message)
                default:
                    self.isSubmitting = false
                    let message = payload["message"] as? String ?? "当前页面没有可用的提交按钮。"
                    self.appendLog("\(source)失败：\(message)", level: .error, category: .submit)
                    self.notice = UserNotice(
                        title: "无法提交",
                        message: message
                    )
                }
            }
        }
    }

    fileprivate func prepareForNewSurvey(_ url: URL) {
        cancelPendingAutoSubmit()
        resetQueueSummary()
        isFilling = false
        isSubmitting = false
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("打开问卷：\(url.absoluteString)", category: .page)
    }

    fileprivate func handleNavigationStarted(in webView: WKWebView) {
        cancelPendingAutoSubmit()
        state = .loading
        canGoBack = false
        if let url = webView.url {
            appendLog("正在加载页面：\(url.absoluteString)", category: .page)
        }
    }

    fileprivate func updateNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
    }

    fileprivate func handlePageLoaded(
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        if let webView {
            updateNavigationState(from: webView)
        }
        scanPage { [weak self] scannedState in
            guard let self else { return }
            if let scheduled = self.pendingScheduledBatch {
                self.pendingScheduledBatch = nil
                guard case .ready(_) = scannedState else {
                    let message = "整点刷新后问卷未进入可填写状态。"
                    self.queueState = .stopped(message)
                    self.queueSnapshot.detail = message
                    self.appendLog(message, level: .warning, category: .batch)
                    self.notice = UserNotice(title: "整点填写未启动", message: message)
                    return
                }
                self.appendLog("整点刷新完成，开始同步填写 10 组。", category: .batch)
                self.startParallelTest(
                    presets: scheduled.presets,
                    surveyURL: scheduled.surveyURL
                )
                return
            }
            if !self.isQueueRunning, autoFillOnLoad, case .ready(_) = scannedState {
                if autoSubmitAfterFill {
                    guard !self.hasAutoSubmittedCurrentForm else { return }
                    self.fillAndSubmit(
                        rules: defaultRules,
                        submitDelaySeconds: submitDelaySeconds,
                        silent: true
                    )
                } else {
                    self.fill(rules: defaultRules, silent: true)
                }
            }
        }
    }

    fileprivate func handleNavigationFailure(_ error: Error) {
        let message = error.localizedDescription
        cancelPendingAutoSubmit()
        isFilling = false
        isSubmitting = false
        state = .failed(message)
        appendLog("页面加载失败：\(message)", level: .error, category: .page)
        if pendingScheduledBatch != nil {
            pendingScheduledBatch = nil
            queueState = .stopped(message)
            queueSnapshot.detail = message
            notice = UserNotice(title: "整点刷新失败", message: message)
        }
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
            let detail = active > 0 ? "正在填写 \(active) 组" : "正在调度批量任务"
            queueState = .running(current: completed, total: total, presetName: detail)
            queueSnapshot = ParallelRunSnapshot(
                completed: completed,
                total: total,
                succeeded: succeeded,
                failed: failed,
                active: active,
                detail: detail
            )
            appendLog("同步填写已启动：共 \(total) 组，当前不会提交。", category: .batch)

        case "prepared":
            let prepared = payload["prepared"] as? Int ?? 0
            batchPreparedCount = prepared
            let detail = "已填写 \(prepared)/\(total)"
            queueState = .running(current: prepared, total: total, presetName: detail)
            queueSnapshot = ParallelRunSnapshot(
                completed: prepared,
                total: total,
                succeeded: 0,
                failed: 0,
                active: active,
                detail: detail
            )
            appendLog("\(presetName)已填写并保留；准备进度 \(prepared)/\(total)。", category: .batch)

        case "readyToSubmit":
            let prepared = payload["prepared"] as? Int ?? total
            batchPreparedCount = prepared
            isBatchReadyToSubmit = true
            let detail = "10 组已填写，等待手动提交"
            queueState = .running(current: prepared, total: total, presetName: detail)
            queueSnapshot = ParallelRunSnapshot(
                completed: prepared,
                total: total,
                succeeded: 0,
                failed: 0,
                active: active,
                detail: detail
            )
            appendLog("10 组全部填写完成，等待手动点击同步提交。", level: .success, category: .batch)

        case "submittingAll":
            isBatchReadyToSubmit = false
            isBatchSubmitting = true
            let detail = "10 组正在同步提交"
            queueState = .running(current: 0, total: total, presetName: detail)
            queueSnapshot = ParallelRunSnapshot(
                completed: 0,
                total: total,
                succeeded: 0,
                failed: 0,
                active: active,
                detail: detail
            )
            appendLog("10 组提交已同时触发，正在等待问卷星返回结果。", category: .batch)

        case "progress":
            isBatchSubmitting = true
            let detail = active > 0 ? "正在等待同步提交结果" : "正在汇总结果"
            queueState = .running(current: completed, total: total, presetName: detail)
            queueSnapshot = ParallelRunSnapshot(
                completed: completed,
                total: total,
                succeeded: succeeded,
                failed: failed,
                active: active,
                detail: presetName
            )
            if taskError.isEmpty {
                appendLog("\(presetName)提交完成；总进度 \(completed)/\(total)。", level: .success, category: .batch)
            } else {
                appendLog("\(presetName)提交失败：\(taskError)", level: .error, category: .batch)
            }

        case "complete":
            clearQueueSession()
            queueState = .completed(total: succeeded)
            queueSnapshot = ParallelRunSnapshot(
                completed: total,
                total: total,
                succeeded: succeeded,
                failed: failed,
                active: 0,
                detail: "全部任务已完成"
            )
            appendLog("批量提交完成：成功 \(succeeded)，失败 \(failed)。", level: failed == 0 ? .success : .warning, category: .batch)
            notice = UserNotice(
                title: "批量任务完成",
                message: "成功 \(succeeded) 个，失败 \(failed) 个，共处理 \(total) 个预设。"
            )

        case "fatal":
            stopQueue(
                message: payload["message"] as? String ?? "批量任务已停止。",
                showNotice: true
            )

        case "stopped":
            stopQueue(message: "批量任务已停止。", showNotice: false)

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
        queueSnapshot.active = 0
        queueSnapshot.detail = message
        let category: AutomationLogCategory = message.contains("验证") ? .security : .batch
        appendLog(message, level: .warning, category: category)
        if showNotice {
            notice = UserNotice(title: "批量任务已停止", message: message)
        }
    }

    private func validatedBatchPresets(
        _ presets: [SubmissionPreset],
        action: String
    ) -> [SubmissionPreset]? {
        let usablePresets = Array(presets.filter { $0.isQueueReady }.prefix(RuleStore.presetCount))
        guard usablePresets.count == RuleStore.presetCount else {
            appendLog("\(action)失败：10 组预设未填写完整。", level: .warning, category: .batch)
            notice = UserNotice(
                title: "预设未填写完整",
                message: "请先完整填写 10 组不同的姓名、工号和固定邮箱。"
            )
            return nil
        }

        for keyword in SubmissionPreset.requiredQuestions {
            let values = usablePresets.map { $0.answer(for: keyword).lowercased() }
            guard Set(values).count == RuleStore.presetCount else {
                appendLog("\(action)失败：10 组预设的\(keyword)存在重复。", level: .warning, category: .batch)
                notice = UserNotice(
                    title: "预设内容重复",
                    message: "10 组预设的\(keyword)必须各不相同。"
                )
                return nil
            }
        }
        return usablePresets
    }

    private func updateBatchScheduleCountdown() {
        guard let target = scheduledBatchTarget else {
            batchScheduleRemainingSeconds = 0
            return
        }
        batchScheduleRemainingSeconds = max(Int(ceil(target.timeIntervalSinceNow)), 0)
    }

    private func fireScheduledBatch() {
        guard let target = scheduledBatchTarget,
              let scheduled = scheduledBatch else { return }

        batchScheduleWorkItem = nil
        batchScheduleTimer?.invalidate()
        batchScheduleTimer = nil
        scheduledBatchTarget = nil
        scheduledBatch = nil
        batchScheduleRemainingSeconds = 0

        let lateness = Date().timeIntervalSince(target)
        guard UIApplication.shared.applicationState == .active, lateness <= 2 else {
            let message = "App 未在整点保持前台，定时任务已取消。"
            queueState = .stopped(message)
            queueSnapshot.detail = message
            appendLog(message, level: .warning, category: .batch)
            notice = UserNotice(title: "错过整点执行", message: message)
            return
        }
        guard let webView else {
            let message = "问卷页面不可用，无法执行整点刷新。"
            queueState = .stopped(message)
            queueSnapshot.detail = message
            appendLog(message, level: .error, category: .batch)
            notice = UserNotice(title: "整点刷新失败", message: message)
            return
        }

        pendingScheduledBatch = scheduled
        cancelPendingAutoSubmit()
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("到达活动整点，正在强制刷新问卷。", category: .batch)
        guard webView.reloadFromOrigin() != nil else {
            pendingScheduledBatch = nil
            let message = "网页未接受刷新请求，整点任务已停止。"
            queueState = .stopped(message)
            queueSnapshot.detail = message
            appendLog(message, level: .error, category: .batch)
            notice = UserNotice(title: "整点刷新失败", message: message)
            return
        }
    }

    private func cancelScheduledBatch(logCancellation: Bool) {
        let hadSchedule = scheduledBatchTarget != nil
        batchScheduleWorkItem?.cancel()
        batchScheduleWorkItem = nil
        batchScheduleTimer?.invalidate()
        batchScheduleTimer = nil
        scheduledBatchTarget = nil
        scheduledBatch = nil
        batchScheduleRemainingSeconds = 0
        if hadSchedule, logCancellation {
            queueState = .idle
            queueSnapshot = ParallelRunSnapshot()
            appendLog("整点任务已取消。", level: .warning, category: .batch)
        }
    }

    private func clearQueueSession() {
        queueSessionID = nil
        queuedPresets = []
        parallelRunID = nil
        batchPreparedCount = 0
        isBatchReadyToSubmit = false
        isBatchSubmitting = false
        isSubmitting = false
        endBackgroundExecution()
    }

    private func beginBackgroundExecution() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WJXParallelTest") { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isQueueRunning else { return }
                self.stopQueue(message: "iOS 后台执行时间已到，批量任务已停止。", showNotice: true)
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func scheduleAutoSubmit(showScheduledNotice: Bool, delaySeconds: Int) {
        cancelPendingAutoSubmit()
        let safeDelay = min(max(delaySeconds, 0), RuleStore.maximumSubmitDelaySeconds)
        isWaitingToSubmit = true
        appendLog("填写已完成，等待 \(safeDelay) 秒后提交。", category: .submit)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAutoSubmitWorkItem = nil
            self.isWaitingToSubmit = false
            guard !self.isQueueRunning else { return }
            self.submitOnce(showScheduledNotice: showScheduledNotice, source: "自动提交")
        }
        pendingAutoSubmitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(safeDelay), execute: workItem)
    }

    private func inspectSingleSubmitResult(source: String, attempt: Int) {
        guard isSubmitting else { return }
        guard let webView else {
            isSubmitting = false
            appendLog("\(source)结果检查失败：问卷页面已关闭。", level: .error, category: .submit)
            return
        }

        if webView.isLoading {
            guard attempt < 4 else {
                isSubmitting = false
                appendLog("\(source)结果检查超时：页面持续加载。", level: .warning, category: .submit)
                notice = UserNotice(title: "结果检查超时", message: "页面仍在加载，请查看当前问卷页面和运行日志。")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.inspectSingleSubmitResult(source: source, attempt: attempt + 1)
            }
            return
        }

        scanPage { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready(_):
                self.appendLog("\(source)未完成：页面仍停留在问卷，可能存在必填项或格式错误。", level: .warning, category: .submit)
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

    private func cancelPendingAutoSubmit() {
        pendingAutoSubmitWorkItem?.cancel()
        pendingAutoSubmitWorkItem = nil
        isWaitingToSubmit = false
    }

    private func resetQueueSummary() {
        guard !isQueueRunning else { return }
        queueState = .idle
        queueSnapshot = ParallelRunSnapshot()
    }

    private func appendLog(
        _ message: String,
        level: AutomationLogLevel = .info,
        category: AutomationLogCategory = .system
    ) {
        logs.append(
            AutomationLogEntry(
                timestamp: Date(),
                level: level,
                category: category,
                message: message
            )
        )
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func logPageState(_ state: SurveyPageState) {
        switch state {
        case .loading:
            break
        case .ready(let questionCount):
            appendLog("页面已就绪，检测到 \(questionCount) 道题。", category: .page)
        case .submitted(let message):
            appendLog("提交成功：\(message)", level: .success, category: .submit)
        case .closed(let message):
            appendLog("问卷不可填写：\(message)", level: .warning, category: .page)
        case .captchaRequired:
            appendLog("页面要求人机验证。", level: .warning, category: .security)
        case .failed(let message):
            appendLog("页面处理失败：\(message)", level: .error, category: .page)
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
    let submitDelaySeconds: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Keep WJX draft-recovery state from carrying across app launches.
        configuration.websiteDataStore = .nonPersistent()
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
                autoSubmitAfterFill: parent.autoSubmitAfterFill,
                submitDelaySeconds: parent.submitDelaySeconds
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
