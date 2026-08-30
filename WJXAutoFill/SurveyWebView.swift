import Foundation
import SwiftUI
import UIKit
import WebKit

private final class SurveyWebLoadGate {
    static let shared = SurveyWebLoadGate(maximumConcurrentLoads: Int.max)

    private struct PendingLoad {
        let id: UUID
        let isPriority: Bool
        let start: () -> Bool
    }

    private let maximumConcurrentLoads: Int
    private var activeLoadIDs: Set<UUID> = []
    private var pendingLoads: [PendingLoad] = []

    private init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(maximumConcurrentLoads, 1)
    }

    func enqueue(
        id: UUID,
        priority: Bool,
        start: @escaping () -> Bool
    ) {
        pendingLoads.removeAll { $0.id == id }
        activeLoadIDs.remove(id)
        let load = PendingLoad(id: id, isPriority: priority, start: start)
        if priority,
           let firstBackgroundIndex = pendingLoads.firstIndex(where: { !$0.isPriority }) {
            pendingLoads.insert(load, at: firstBackgroundIndex)
        } else {
            pendingLoads.append(load)
        }
        drain()
    }

    func promote(id: UUID) {
        guard let index = pendingLoads.firstIndex(where: { $0.id == id }) else { return }
        let load = pendingLoads.remove(at: index)
        pendingLoads.insert(
            PendingLoad(id: load.id, isPriority: true, start: load.start),
            at: 0
        )
        drain()
    }

    func cancel(id: UUID, drainQueue: Bool = true) {
        pendingLoads.removeAll { $0.id == id }
        if activeLoadIDs.remove(id) != nil, drainQueue {
            drain()
        }
    }

    func finish(id: UUID) {
        let removedPending = pendingLoads.contains { $0.id == id }
        pendingLoads.removeAll { $0.id == id }
        let removedActive = activeLoadIDs.remove(id) != nil
        if removedPending || removedActive {
            drain()
        }
    }

    private func drain() {
        while activeLoadIDs.count < maximumConcurrentLoads,
              !pendingLoads.isEmpty {
            let load = pendingLoads.removeFirst()
            activeLoadIDs.insert(load.id)
            if !load.start() {
                activeLoadIDs.remove(load.id)
            }
        }
    }
}

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
    @Published private(set) var isAwaitingCaptchaCompletion = false
    /// 当前表单是否已经填入过内容，同步提交据此判断页面是否真的“填好在等”。
    @Published private(set) var hasFilledCurrentForm = false
    @Published private(set) var logs: [AutomationLogEntry] = []

    fileprivate weak var webView: WKWebView?
    private var queuedPresets: [SubmissionPreset] = []
    private var queueSessionID: UUID?
    private var parallelRunID: String?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var hasAutoSubmittedCurrentForm = false
    private var captchaWatchID: UUID?
    private var captchaWatchTicks = 0
    private var captchaResumeCount = 0
    private var pendingAutoSubmitWorkItem: DispatchWorkItem?
    private var scheduledBatch: (presets: [SubmissionPreset], surveyURL: URL)?
    private var pendingScheduledBatch: (presets: [SubmissionPreset], surveyURL: URL)?
    private var batchScheduleWorkItem: DispatchWorkItem?
    private var batchScheduleTimer: Timer?
    private var countdownResumeID: UUID?
    private var navigationGeneration = 0
    private var handledCountdownClickGeneration: Int?
    private var pendingScheduledBatchID: UUID?
    private var pendingScheduledBatchTimeoutWorkItem: DispatchWorkItem?
    private var componentReadinessID: UUID?
    private var pageRecoveryID: UUID?
    private var pageRecoveryWorkItem: DispatchWorkItem?
    private var currentSurveyURL: URL?
    private var automaticPageRecoveryAttempts = 0
    private var loadGateRequestID: UUID?
    private var loadStartWatchdogWorkItem: DispatchWorkItem?
    private var isPageSelected = false
    private var isOfficialAPIMode = false
    private var requestHeaderProfiles: [RequestHeaderProfile] = []

    private static let maximumAutomaticPageRecoveryAttempts = 2
    private static let maximumComponentReadinessAttempts = 20
    /// 人机验证交给用户手动完成，这里只负责轮询等待验证消失，不做任何绕过。
    private static let captchaWatchInterval: TimeInterval = 1.5
    private static let maximumCaptchaWatchTicks = 160
    private static let maximumCaptchaResumes = 3

    private enum FillEvaluation {
        case success(matched: Int, filled: Int)
        case closed(String)
        case failed(String)
    }

    deinit {
        batchScheduleWorkItem?.cancel()
        batchScheduleTimer?.invalidate()
        pendingScheduledBatchTimeoutWorkItem?.cancel()
        pageRecoveryWorkItem?.cancel()
        loadStartWatchdogWorkItem?.cancel()
        if let loadGateRequestID {
            SurveyWebLoadGate.shared.cancel(id: loadGateRequestID)
        }
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
        guard !isOfficialAPIMode, !isBusy else { return false }
        if case .ready(_) = state { return true }
        return false
    }

    var canAttemptSubmit: Bool {
        guard !isOfficialAPIMode, !isBusy else { return false }
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

    func prepareForOfficialAPIMode() {
        setOfficialAPIMode(true)
    }

    fileprivate func setOfficialAPIMode(_ enabled: Bool) {
        guard enabled != isOfficialAPIMode else { return }
        isOfficialAPIMode = enabled
        guard enabled else {
            appendLog("已退出官方 API 模式，可继续使用网页自动化。", category: .system)
            return
        }

        cancelPendingAutoSubmit()
        cancelCaptchaWatch()
        cancelScheduledBatch(logCancellation: false)
        clearPendingScheduledBatch()
        if let runID = parallelRunID,
           let script = AutomationScript.cancelParallel(runID: runID) {
            webView?.evaluateJavaScript(script)
        }
        if isQueueRunning {
            stopQueue(message: "已切换到官方 API 模式，网页批量任务已停止。", showNotice: false)
        }
        isWaitingToSubmit = false
        hasAutoSubmittedCurrentForm = false
        appendLog("已启用官方 API 模式，网页自动填写和网页提交已停用。", category: .system)
    }

    func shutdown() {
        stopCountdownAutomation()
        cancelComponentReadinessCheck()
        cancelAutomaticPageRecovery()
        cancelProgrammaticLoad(stopLoading: true)
        cancelPendingAutoSubmit()
        cancelCaptchaWatch()
        cancelScheduledBatch(logCancellation: false)
        clearPendingScheduledBatch()
        if let runID = parallelRunID,
           let script = AutomationScript.cancelParallel(runID: runID) {
            webView?.evaluateJavaScript(script)
        }
        clearQueueSession()
        webView?.stopLoading()
        webView = nil
    }

    @discardableResult
    func reopenSurvey(_ url: URL) -> Bool {
        guard !isBusy, webView != nil else { return false }
        prepareForNewSurvey(url)
        appendLog("按已保存地址重新打开问卷：\(url.absoluteString)", category: .page)
        guard scheduleProgrammaticLoad(
            url: url,
            cachePolicy: .reloadRevalidatingCacheData
        ) else {
            let message = "网页未接受打开问卷的请求。"
            state = .failed(message)
            appendLog(message, level: .error, category: .page)
            notice = UserNotice(title: "打开问卷失败", message: message)
            return false
        }
        return true
    }

    fileprivate func setPageSelected(_ isSelected: Bool) {
        isPageSelected = isSelected
        if isSelected, let loadGateRequestID {
            SurveyWebLoadGate.shared.promote(id: loadGateRequestID)
        }
    }

    fileprivate func setRequestHeaderProfiles(_ profiles: [RequestHeaderProfile]) {
        requestHeaderProfiles = profiles
    }

    @discardableResult
    fileprivate func scheduleProgrammaticLoad(
        url: URL,
        cachePolicy: URLRequest.CachePolicy,
        forcePriority: Bool = false
    ) -> Bool {
        guard let webView else { return false }
        cancelProgrammaticLoad(stopLoading: true, drainQueue: false)
        let requestID = UUID()
        loadGateRequestID = requestID
        SurveyWebLoadGate.shared.enqueue(
            id: requestID,
            priority: forcePriority || isPageSelected
        ) { [weak self, weak webView] in
            guard let self,
                  let webView,
                  self.loadGateRequestID == requestID,
                  self.webView === webView else {
                return false
            }
            self.startLoadStartWatchdog(requestID: requestID)
            var request = URLRequest(
                url: url,
                cachePolicy: cachePolicy,
                timeoutInterval: 30
            )
            RequestHeaderResolver.apply(
                profiles: self.requestHeaderProfiles,
                to: &request
            )
            let navigation = webView.load(request)
            guard navigation != nil else {
                self.cancelLoadStartWatchdog()
                self.loadGateRequestID = nil
                DispatchQueue.main.async { [weak self] in
                    self?.handleLoadRequestRejected()
                }
                return false
            }
            return true
        }
        return true
    }

    fileprivate func finishProgrammaticLoad() {
        guard let requestID = loadGateRequestID else { return }
        cancelLoadStartWatchdog()
        loadGateRequestID = nil
        SurveyWebLoadGate.shared.finish(id: requestID)
    }

    fileprivate var hasProgrammaticLoadInFlight: Bool {
        loadGateRequestID != nil
    }

    fileprivate var programmaticLoadRequestID: UUID? {
        loadGateRequestID
    }

    fileprivate func handleProgrammaticNavigationStarted() {
        cancelLoadStartWatchdog()
    }

    private func cancelProgrammaticLoad(
        stopLoading: Bool,
        drainQueue: Bool = true
    ) {
        guard let requestID = loadGateRequestID else { return }
        cancelLoadStartWatchdog()
        loadGateRequestID = nil
        SurveyWebLoadGate.shared.cancel(id: requestID, drainQueue: drainQueue)
        if stopLoading {
            webView?.stopLoading()
        }
    }

    private func startLoadStartWatchdog(requestID: UUID) {
        cancelLoadStartWatchdog()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.loadGateRequestID == requestID else { return }
            self.loadStartWatchdogWorkItem = nil
            if self.attemptAutomaticPageRecovery(reason: "网页加载请求长时间未启动") {
                return
            }
            self.finishComponentReadinessFailure("网页加载请求未能正常启动，请点击刷新重试。")
        }
        loadStartWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func cancelLoadStartWatchdog() {
        loadStartWatchdogWorkItem?.cancel()
        loadStartWatchdogWorkItem = nil
    }

    func goBack() {
        guard !isBusy,
              let webView, webView.canGoBack else { return }
        stopCountdownAutomation()
        cancelPendingAutoSubmit()
        hasAutoSubmittedCurrentForm = false
        hasFilledCurrentForm = false
        state = .loading
        appendLog("返回上一页。", category: .page)
        guard webView.goBack() != nil else {
            let message = "网页未接受返回请求。"
            state = .failed(message)
            appendLog(message, level: .error, category: .page)
            notice = UserNotice(title: "返回失败", message: message)
            return
        }
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
                self.hasFilledCurrentForm = self.hasFilledCurrentForm || filled > 0
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
                self.hasFilledCurrentForm = self.hasFilledCurrentForm || filled > 0
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

                guard !self.isOfficialAPIMode else {
                    self.appendLog("已切换到官方 API 模式，本次网页自动提交已取消。", level: .warning, category: .submit)
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
        guard !isOfficialAPIMode else {
            appendLog("官方 API 模式已开启，未启动网页同步填写。", level: .warning, category: .batch)
            return
        }
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

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
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

    // MARK: - 同步提交自检
    //
    // 同步提交只是把多页各自的“点自己页面上的提交按钮”安排在同一时刻，
    // 不合并、不代发任何请求，所以每一页都要先自己确认状态可提交。

    /// 返回 nil 表示这一页可以立刻提交；否则给出应当跳过的原因。
    var syncSubmitBlockReason: String? {
        if isOfficialAPIMode {
            return "官方 API 模式已开启"
        }
        if isAwaitingCaptchaCompletion {
            return "正在等待你手动完成人机验证"
        }
        switch state {
        case .loading:
            return "页面仍在加载"
        case .submitted:
            return "本页已经提交过"
        case .closed:
            return "问卷当前不可提交"
        case .captchaRequired:
            return "需要先手动完成人机验证"
        case .failed(let message):
            return message.isEmpty ? "页面状态异常" : message
        case .ready(let questionCount):
            if questionCount <= 0 {
                return "页面还没有识别到题目"
            }
            if isSubmitting || isWaitingToSubmit {
                return "本页正在提交中"
            }
            if isBusy {
                return "本页正忙"
            }
            if !hasFilledCurrentForm {
                return "本页还没有填写内容"
            }
            if !canAttemptSubmit {
                return "本页暂时不能提交"
            }
            return nil
        }
    }

    func noteSyncSubmitSkipped(reason: String) {
        appendLog("同步提交跳过本页：\(reason)", level: .warning, category: .submit)
    }

    func submitOnce(showScheduledNotice: Bool = true, source: String = "手动提交") {
        guard !isOfficialAPIMode, !isBusy else { return }
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
                    self.notice = UserNotice(
                        title: "需要人机验证",
                        message: "应用不会绕过验证码。请在页面中手动完成验证，完成后会自动继续提交。"
                    )
                    self.beginCaptchaWatch()
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
        cancelComponentReadinessCheck()
        cancelAutomaticPageRecovery()
        cancelProgrammaticLoad(stopLoading: true)
        stopCountdownAutomation()
        cancelPendingAutoSubmit()
        cancelCaptchaWatch()
        resetQueueSummary()
        currentSurveyURL = url
        automaticPageRecoveryAttempts = 0
        isFilling = false
        isSubmitting = false
        hasAutoSubmittedCurrentForm = false
        hasFilledCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("打开问卷：\(url.absoluteString)", category: .page)
    }

    @discardableResult
    fileprivate func handleNavigationStarted(in webView: WKWebView) -> Int {
        cancelComponentReadinessCheck()
        cancelAutomaticPageRecovery()
        stopCountdownAutomation()
        cancelPendingAutoSubmit()
        hasFilledCurrentForm = false
        state = .loading
        canGoBack = false
        if let url = webView.url {
            appendLog("正在加载页面：\(url.absoluteString)", category: .page)
        }
        return navigationGeneration
    }

    fileprivate func updateNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
    }

    fileprivate func handleDraftRecoveryPromptAutoCancelled() {
        appendLog(
            "已自动取消“继续上次回答”提示，将使用当前页面重新填写。",
            level: .success,
            category: .page
        )
    }

    fileprivate func handlePageLoaded(
        navigationGeneration expectedGeneration: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        guard navigationGeneration == expectedGeneration else { return }
        let generation = expectedGeneration
        if let webView {
            updateNavigationState(from: webView)
        }
        installCountdownAutoStart(generation: generation) { [weak self] autoStartStatus in
            guard let self, self.navigationGeneration == generation else { return }
            if autoStartStatus == "clicked" {
                self.finishProgrammaticLoad()
                self.automaticPageRecoveryAttempts = 0
                self.state = .loading
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self,
                          self.navigationGeneration == generation,
                          self.handledCountdownClickGeneration != generation else { return }
                    self.handledCountdownClickGeneration = generation
                    self.appendLog(
                        "倒计时结束，已自动点击“立即开始”。",
                        level: .success,
                        category: .page
                    )
                    self.scheduleCountdownResume(
                        generation: generation,
                        defaultRules: defaultRules,
                        autoFillOnLoad: autoFillOnLoad,
                        autoSubmitAfterFill: autoSubmitAfterFill,
                        submitDelaySeconds: submitDelaySeconds
                    )
                }
                return
            }
            if autoStartStatus == "waiting" {
                self.finishProgrammaticLoad()
                self.automaticPageRecoveryAttempts = 0
                self.state = .loading
                self.appendLog("检测到活动倒计时，等待自动点击“立即开始”。", category: .page)
                return
            }
            self.beginComponentReadinessCheck(
                generation: generation,
                defaultRules: defaultRules,
                autoFillOnLoad: autoFillOnLoad,
                autoSubmitAfterFill: autoSubmitAfterFill,
                submitDelaySeconds: submitDelaySeconds
            )
        }
    }

    fileprivate func handleCountdownAutoStartMessage(
        _ body: Any,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        guard let payload = Self.dictionary(from: body),
              let type = payload["type"] as? String,
              type == "clicked" || type == "ready",
              let generation = Self.integer(from: payload["generation"]),
              generation == navigationGeneration,
              handledCountdownClickGeneration != generation else { return }
        handledCountdownClickGeneration = generation
        automaticPageRecoveryAttempts = 0
        if type == "clicked" {
            let label = payload["label"] as? String ?? "立即开始"
            appendLog("倒计时结束，已自动点击“\(label)”。", level: .success, category: .page)
        } else {
            appendLog("页面已进入可填写状态，正在检测题目。", level: .success, category: .page)
        }
        scheduleCountdownResume(
            generation: generation,
            defaultRules: defaultRules,
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
    }

    private func installCountdownAutoStart(
        generation: Int,
        completion: @escaping (String) -> Void
    ) {
        guard let webView else {
            completion("unavailable")
            return
        }
        var hasCompleted = false
        let finish: (String) -> Void = { status in
            guard !hasCompleted else { return }
            hasCompleted = true
            completion(status)
        }
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.navigationGeneration == generation else { return }
            finish("unavailable")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeoutWorkItem)
        let script = AutomationScript.installCountdownAutoStart(generation: generation)
        webView.evaluateJavaScript(script) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.navigationGeneration == generation else { return }
                timeoutWorkItem.cancel()
                guard error == nil,
                      let payload = Self.dictionary(from: result),
                      Self.integer(from: payload["generation"]) == generation else {
                    finish("unavailable")
                    return
                }
                finish(payload["status"] as? String ?? "watching")
            }
        }
    }

    private func beginComponentReadinessCheck(
        generation: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        cancelComponentReadinessCheck()
        let readinessID = UUID()
        componentReadinessID = readinessID
        scheduleComponentReadinessCheck(
            readinessID: readinessID,
            generation: generation,
            attempt: 0,
            defaultRules: defaultRules,
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
    }

    private func scheduleComponentReadinessCheck(
        readinessID: UUID,
        generation: Int,
        attempt: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        let delay = attempt == 0 ? 0.12 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.componentReadinessID == readinessID,
                  self.navigationGeneration == generation else { return }
            guard let webView = self.webView else {
                self.finishComponentReadinessFailure("问卷页面已关闭。")
                return
            }
            if webView.isLoading {
                self.retryComponentReadinessCheck(
                    readinessID: readinessID,
                    generation: generation,
                    attempt: attempt,
                    diagnostic: "网页仍在加载",
                    defaultRules: defaultRules,
                    autoFillOnLoad: autoFillOnLoad,
                    autoSubmitAfterFill: autoSubmitAfterFill,
                    submitDelaySeconds: submitDelaySeconds
                )
                return
            }

            var evaluationFinished = false
            let evaluationTimeout = DispatchWorkItem { [weak self] in
                guard let self,
                      !evaluationFinished,
                      self.componentReadinessID == readinessID,
                      self.navigationGeneration == generation else { return }
                evaluationFinished = true
                self.retryComponentReadinessCheck(
                    readinessID: readinessID,
                    generation: generation,
                    attempt: attempt,
                    diagnostic: "组件检测没有响应",
                    defaultRules: defaultRules,
                    autoFillOnLoad: autoFillOnLoad,
                    autoSubmitAfterFill: autoSubmitAfterFill,
                    submitDelaySeconds: submitDelaySeconds
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: evaluationTimeout)
            webView.evaluateJavaScript(AutomationScript.readiness) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self,
                          !evaluationFinished,
                          self.componentReadinessID == readinessID,
                          self.navigationGeneration == generation else { return }
                    evaluationFinished = true
                    evaluationTimeout.cancel()
                    let payload = Self.dictionary(from: result)
                    if error == nil, payload?["ready"] as? Bool == true {
                        self.componentReadinessID = nil
                        self.scanPage(expectedNavigationGeneration: generation) { [weak self] scannedState in
                            guard let self, self.navigationGeneration == generation else { return }
                            switch scannedState {
                            case .ready(let questionCount) where questionCount > 0:
                                self.finishProgrammaticLoad()
                                self.automaticPageRecoveryAttempts = 0
                            case .submitted, .closed, .captchaRequired:
                                self.finishProgrammaticLoad()
                                self.automaticPageRecoveryAttempts = 0
                            case .ready:
                                if self.attemptAutomaticPageRecovery(
                                    reason: "页面已完成加载，但未检测到题目控件"
                                ) {
                                    return
                                }
                                self.finishComponentReadinessFailure(
                                    "页面未检测到可填写题目，自动恢复后仍未就绪。"
                                )
                                return
                            case .failed(let message):
                                if self.attemptAutomaticPageRecovery(
                                    reason: "页面状态检测失败：\(message)"
                                ) {
                                    return
                                }
                                self.finishComponentReadinessFailure(message)
                                return
                            case .loading:
                                if self.attemptAutomaticPageRecovery(
                                    reason: "页面状态持续停留在加载中"
                                ) {
                                    return
                                }
                                self.finishComponentReadinessFailure("页面状态持续停留在加载中。")
                                return
                            }
                            self.processScannedPage(
                                scannedState,
                                generation: generation,
                                defaultRules: defaultRules,
                                autoFillOnLoad: autoFillOnLoad,
                                autoSubmitAfterFill: autoSubmitAfterFill,
                                submitDelaySeconds: submitDelaySeconds
                            )
                        }
                        return
                    }

                    let diagnostic = self.componentReadinessDiagnostic(
                        payload: payload,
                        error: error
                    )
                    self.retryComponentReadinessCheck(
                        readinessID: readinessID,
                        generation: generation,
                        attempt: attempt,
                        diagnostic: diagnostic,
                        defaultRules: defaultRules,
                        autoFillOnLoad: autoFillOnLoad,
                        autoSubmitAfterFill: autoSubmitAfterFill,
                        submitDelaySeconds: submitDelaySeconds
                    )
                }
            }
        }
    }

    private func retryComponentReadinessCheck(
        readinessID: UUID,
        generation: Int,
        attempt: Int,
        diagnostic: String,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        guard attempt < Self.maximumComponentReadinessAttempts else {
            componentReadinessID = nil
            if attemptAutomaticPageRecovery(reason: "网页组件未完整加载：\(diagnostic)") {
                return
            }
            finishComponentReadinessFailure(
                "网页核心组件未完整加载，自动恢复后仍未就绪。"
            )
            return
        }
        scheduleComponentReadinessCheck(
            readinessID: readinessID,
            generation: generation,
            attempt: attempt + 1,
            defaultRules: defaultRules,
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
    }

    private func componentReadinessDiagnostic(
        payload: [String: Any]?,
        error: Error?
    ) -> String {
        if let error { return error.localizedDescription }
        guard let payload else { return "无法读取组件状态" }
        let readyState = payload["readyState"] as? String ?? "未知"
        let questionCount = Self.integer(from: payload["questionCount"]) ?? 0
        let hasJQuery = payload["hasJQuery"] as? Bool == true ? "是" : "否"
        let hasSubmit = payload["hasSubmitControl"] as? Bool == true ? "是" : "否"
        return "文档=\(readyState)，题目控件=\(questionCount)，基础脚本=\(hasJQuery)，提交控件=\(hasSubmit)"
    }

    private func cancelComponentReadinessCheck() {
        componentReadinessID = nil
    }

    private func finishComponentReadinessFailure(_ message: String) {
        cancelComponentReadinessCheck()
        cancelAutomaticPageRecovery()
        finishProgrammaticLoad()
        cancelPendingAutoSubmit()
        isFilling = false
        isSubmitting = false
        state = .failed(message)
        appendLog(message, level: .error, category: .page)
        if pendingScheduledBatch != nil {
            stopPendingScheduledBatch(message: message, title: "问卷加载失败")
        } else if isQueueRunning {
            stopQueue(message: message, showNotice: true)
        } else {
            notice = UserNotice(title: "网页加载不完整", message: "已自动重试，请检查网络后点击刷新。")
        }
    }

    private func processScannedPage(
        _ scannedState: SurveyPageState,
        generation: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        guard navigationGeneration == generation else { return }
        switch scannedState {
        case .ready(let questionCount) where questionCount > 0:
            stopCountdownAutomation()
        case .submitted, .closed, .captchaRequired:
            stopCountdownAutomation()
        case .loading, .ready, .failed:
            break
        }

        if let scheduled = pendingScheduledBatch {
            switch scannedState {
            case .loading:
                return
            case .ready(let questionCount) where questionCount <= 0:
                state = .loading
                return
            case .ready(let questionCount) where questionCount > 0:
                clearPendingScheduledBatch()
                appendLog("整点刷新完成，开始同步填写 10 组。", category: .batch)
                startParallelTest(
                    presets: scheduled.presets,
                    surveyURL: scheduled.surveyURL
                )
                return
            case .submitted(let message):
                stopPendingScheduledBatch(
                    message: "整点刷新进入已提交页面：\(message)",
                    title: "整点填写未启动"
                )
                return
            case .closed(let message):
                stopPendingScheduledBatch(
                    message: "整点刷新后问卷不可填写：\(message)",
                    title: "整点填写未启动"
                )
                return
            case .captchaRequired:
                stopPendingScheduledBatch(
                    message: "整点刷新后页面要求人机验证，批量填写未启动。请手动完成验证后重试。",
                    title: "需要人机验证"
                )
                return
            case .failed(let message):
                appendLog(
                    "整点刷新后暂时无法识别页面，正在重试：\(message)",
                    level: .warning,
                    category: .batch
                )
                scheduleCountdownResume(
                    generation: generation,
                    defaultRules: defaultRules,
                    autoFillOnLoad: autoFillOnLoad,
                    autoSubmitAfterFill: autoSubmitAfterFill,
                    submitDelaySeconds: submitDelaySeconds
                )
                return
            case .ready:
                return
            }
        }

        guard !isQueueRunning,
              autoFillOnLoad,
              case .ready(let questionCount) = scannedState,
              questionCount > 0 else { return }
        if autoSubmitAfterFill {
            guard !hasAutoSubmittedCurrentForm else { return }
            fillAndSubmit(
                rules: defaultRules,
                submitDelaySeconds: submitDelaySeconds,
                silent: true
            )
        } else {
            fill(rules: defaultRules, silent: true)
        }
    }

    private func scheduleCountdownResume(
        generation: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        let resumeID = UUID()
        countdownResumeID = resumeID
        state = .loading
        scheduleCountdownScan(
            resumeID: resumeID,
            generation: generation,
            attempt: 0,
            defaultRules: defaultRules,
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
    }

    private func scheduleCountdownScan(
        resumeID: UUID,
        generation: Int,
        attempt: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.countdownResumeID == resumeID,
                  self.navigationGeneration == generation else { return }
            guard let webView = self.webView else {
                self.failCountdownResume("问卷页面已关闭，无法继续检测活动题目。")
                return
            }
            if webView.isLoading {
                self.retryCountdownScan(
                    resumeID: resumeID,
                    generation: generation,
                    attempt: attempt,
                    defaultRules: defaultRules,
                    autoFillOnLoad: autoFillOnLoad,
                    autoSubmitAfterFill: autoSubmitAfterFill,
                    submitDelaySeconds: submitDelaySeconds
                )
                return
            }

            self.scanPage(expectedNavigationGeneration: generation) { [weak self] scannedState in
                guard let self,
                      self.countdownResumeID == resumeID,
                      self.navigationGeneration == generation else { return }
                if case .ready(let questionCount) = scannedState,
                   questionCount > 0 {
                    self.cancelCountdownResume()
                    self.processScannedPage(
                        scannedState,
                        generation: generation,
                        defaultRules: defaultRules,
                        autoFillOnLoad: autoFillOnLoad,
                        autoSubmitAfterFill: autoSubmitAfterFill,
                        submitDelaySeconds: submitDelaySeconds
                    )
                    return
                }

                switch scannedState {
                case .submitted, .closed, .captchaRequired:
                    self.cancelCountdownResume()
                    self.processScannedPage(
                        scannedState,
                        generation: generation,
                        defaultRules: defaultRules,
                        autoFillOnLoad: autoFillOnLoad,
                        autoSubmitAfterFill: autoSubmitAfterFill,
                        submitDelaySeconds: submitDelaySeconds
                    )
                case .loading, .ready, .failed:
                    self.retryCountdownScan(
                        resumeID: resumeID,
                        generation: generation,
                        attempt: attempt,
                        defaultRules: defaultRules,
                        autoFillOnLoad: autoFillOnLoad,
                        autoSubmitAfterFill: autoSubmitAfterFill,
                        submitDelaySeconds: submitDelaySeconds
                    )
                }
            }
        }
    }

    private func retryCountdownScan(
        resumeID: UUID,
        generation: Int,
        attempt: Int,
        defaultRules: [FillRule],
        autoFillOnLoad: Bool,
        autoSubmitAfterFill: Bool,
        submitDelaySeconds: Int
    ) {
        guard attempt < 59 else {
            failCountdownResume("已点击“立即开始”，但未在 30 秒内检测到问卷题目。")
            return
        }
        scheduleCountdownScan(
            resumeID: resumeID,
            generation: generation,
            attempt: attempt + 1,
            defaultRules: defaultRules,
            autoFillOnLoad: autoFillOnLoad,
            autoSubmitAfterFill: autoSubmitAfterFill,
            submitDelaySeconds: submitDelaySeconds
        )
    }

    private func cancelCountdownResume() {
        countdownResumeID = nil
    }

    private func stopCountdownAutomation() {
        let generationToStop = navigationGeneration
        navigationGeneration &+= 1
        handledCountdownClickGeneration = nil
        cancelCountdownResume()
        let script = AutomationScript.stopCountdownAutoStart(generation: generationToStop)
        webView?.evaluateJavaScript(script)
    }

    private func failCountdownResume(_ message: String) {
        stopCountdownAutomation()
        state = .failed(message)
        if pendingScheduledBatch != nil {
            stopPendingScheduledBatch(message: message, title: "整点填写未启动")
        } else {
            appendLog(message, level: .warning, category: .page)
            notice = UserNotice(title: "活动页面加载超时", message: message)
        }
    }

    @discardableResult
    private func attemptAutomaticPageRecovery(reason: String) -> Bool {
        guard !isQueueRunning,
              !isSubmitting,
              !isWaitingToSubmit,
              automaticPageRecoveryAttempts < Self.maximumAutomaticPageRecoveryAttempts,
              let webView,
              let url = currentSurveyURL else {
            return false
        }

        cancelComponentReadinessCheck()
        cancelAutomaticPageRecovery()
        cancelPendingAutoSubmit()
        isFilling = false
        automaticPageRecoveryAttempts += 1
        let attempt = automaticPageRecoveryAttempts
        appendLog(
            "检测到网页加载异常，正在自动恢复（\(attempt)/\(Self.maximumAutomaticPageRecoveryAttempts)）：\(reason)",
            level: .warning,
            category: .page
        )

        stopCountdownAutomation()
        webView.stopLoading()
        state = .loading

        let recoveryID = UUID()
        pageRecoveryID = recoveryID
        let workItem = DispatchWorkItem { [weak self, weak webView] in
            guard let self,
                  let webView,
                  self.pageRecoveryID == recoveryID,
                  self.webView === webView else { return }
            self.pageRecoveryID = nil
            self.pageRecoveryWorkItem = nil
            let cachePolicy: URLRequest.CachePolicy = attempt == 1
                ? .reloadRevalidatingCacheData
                : .reloadIgnoringLocalAndRemoteCacheData
            guard self.scheduleProgrammaticLoad(
                url: url,
                cachePolicy: cachePolicy
            ) else {
                self.finishComponentReadinessFailure("网页未接受自动恢复请求。")
                return
            }
        }
        pageRecoveryWorkItem = workItem
        let delay = 0.25 + Double(attempt - 1) * 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    private func cancelAutomaticPageRecovery() {
        pageRecoveryWorkItem?.cancel()
        pageRecoveryWorkItem = nil
        pageRecoveryID = nil
    }

    fileprivate func handleNavigationStalled(
        navigationGeneration expectedGeneration: Int
    ) {
        guard navigationGeneration == expectedGeneration else { return }
        if attemptAutomaticPageRecovery(reason: "主页面加载超过 25 秒仍未完成") {
            return
        }
        finishComponentReadinessFailure("网页加载超时，请检查网络后刷新。")
    }

    fileprivate func handleWebContentProcessTerminated() {
        if attemptAutomaticPageRecovery(reason: "网页进程因系统资源压力被终止") {
            return
        }
        finishComponentReadinessFailure("网页进程已停止，无法自动恢复。")
    }

    fileprivate func handleLoadRequestRejected() {
        finishComponentReadinessFailure("网页未接受加载请求，请点击刷新重试。")
    }

    fileprivate func handleNavigationFailure(
        _ error: Error,
        navigationGeneration expectedGeneration: Int
    ) {
        guard navigationGeneration == expectedGeneration else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.finishNavigationFailure(
                    error,
                    expectedGeneration: expectedGeneration
                )
            }
            return
        }
        finishNavigationFailure(error, expectedGeneration: expectedGeneration)
    }

    private func finishNavigationFailure(
        _ error: Error,
        expectedGeneration: Int
    ) {
        guard navigationGeneration == expectedGeneration else { return }
        let message = error.localizedDescription
        if isTransientNavigationError(error as NSError),
           attemptAutomaticPageRecovery(reason: "网络加载失败：\(message)") {
            return
        }
        finishProgrammaticLoad()
        stopCountdownAutomation()
        cancelPendingAutoSubmit()
        isFilling = false
        isSubmitting = false
        state = .failed(message)
        appendLog("页面加载失败：\(message)", level: .error, category: .page)
        if pendingScheduledBatch != nil {
            stopPendingScheduledBatch(message: message, title: "整点刷新失败")
        }
        if isQueueRunning {
            stopQueue(message: "页面加载失败：\(message)", showNotice: true)
        }
    }

    private func isTransientNavigationError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorResourceUnavailable
        ].contains(error.code)
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

    fileprivate func scanPage(
        expectedNavigationGeneration: Int? = nil,
        completion: ((SurveyPageState) -> Void)? = nil
    ) {
        guard let webView else {
            state = .failed("问卷页面不可用。")
            completion?(state)
            return
        }
        webView.evaluateJavaScript(AutomationScript.scan) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let expectedGeneration = expectedNavigationGeneration,
                   self.navigationGeneration != expectedGeneration {
                    return
                }
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
        guard webView != nil else {
            let message = "问卷页面不可用，无法执行整点刷新。"
            queueState = .stopped(message)
            queueSnapshot.detail = message
            appendLog(message, level: .error, category: .batch)
            notice = UserNotice(title: "整点刷新失败", message: message)
            return
        }

        beginPendingScheduledBatch(scheduled)
        stopCountdownAutomation()
        cancelPendingAutoSubmit()
        hasAutoSubmittedCurrentForm = false
        canGoBack = false
        state = .loading
        appendLog("到达活动整点，正在强制刷新问卷。", category: .batch)
        guard scheduleProgrammaticLoad(
            url: scheduled.surveyURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            forcePriority: true
        ) else {
            let message = "网页未接受刷新请求，整点任务已停止。"
            stopPendingScheduledBatch(message: message, title: "整点刷新失败")
            return
        }
    }

    private func beginPendingScheduledBatch(
        _ scheduled: (presets: [SubmissionPreset], surveyURL: URL)
    ) {
        clearPendingScheduledBatch()
        pendingScheduledBatch = scheduled
        let pendingID = UUID()
        pendingScheduledBatchID = pendingID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingScheduledBatchID == pendingID,
                  self.pendingScheduledBatch != nil else { return }
            self.stopCountdownAutomation()
            let message = "整点刷新后等待活动开始超过 5 分钟，批量填写已停止。"
            self.state = .failed(message)
            self.stopPendingScheduledBatch(message: message, title: "等待活动开始超时")
        }
        pendingScheduledBatchTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: workItem)
    }

    private func clearPendingScheduledBatch() {
        pendingScheduledBatchTimeoutWorkItem?.cancel()
        pendingScheduledBatchTimeoutWorkItem = nil
        pendingScheduledBatchID = nil
        pendingScheduledBatch = nil
    }

    private func stopPendingScheduledBatch(message: String, title: String) {
        clearPendingScheduledBatch()
        queueState = .stopped(message)
        queueSnapshot.detail = message
        appendLog(message, level: .warning, category: .batch)
        notice = UserNotice(title: title, message: message)
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
                    message: "请在页面中手动完成验证，完成后会自动继续提交。"
                )
                self.beginCaptchaWatch()
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

    // MARK: - 人机验证交接
    //
    // 这里刻意不做任何绕过：应用只是停下来等用户在页面上亲手完成验证，
    // 轮询发现验证已消失后，替用户把中断的那一次提交接着走完。

    private func beginCaptchaWatch() {
        guard captchaWatchID == nil else { return }
        guard captchaResumeCount < Self.maximumCaptchaResumes else {
            appendLog(
                "本页已等待人工验证 \(captchaResumeCount) 次，不再自动继续，请手动提交。",
                level: .warning,
                category: .security
            )
            return
        }
        let watchID = UUID()
        captchaWatchID = watchID
        captchaWatchTicks = 0
        isAwaitingCaptchaCompletion = true
        appendLog("正在等待你手动完成人机验证，完成后会自动继续提交。", category: .security)
        scheduleCaptchaWatchTick(watchID: watchID)
    }

    private func scheduleCaptchaWatchTick(watchID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captchaWatchInterval) { [weak self] in
            self?.runCaptchaWatchTick(watchID: watchID)
        }
    }

    private func runCaptchaWatchTick(watchID: UUID) {
        guard captchaWatchID == watchID else { return }
        guard webView != nil else {
            finishCaptchaWatch(message: "问卷页面已关闭，等待人工验证结束。", level: .warning)
            return
        }
        captchaWatchTicks += 1
        guard captchaWatchTicks <= Self.maximumCaptchaWatchTicks else {
            finishCaptchaWatch(message: "等待人工完成验证超时，已停止自动继续。", level: .warning)
            return
        }
        if webView?.isLoading == true {
            scheduleCaptchaWatchTick(watchID: watchID)
            return
        }

        scanPage { [weak self] state in
            guard let self, self.captchaWatchID == watchID else { return }
            switch state {
            case .ready:
                self.captchaResumeCount += 1
                self.finishCaptchaWatch(
                    message: "人机验证已完成，正在继续提交（第 \(self.captchaResumeCount) 次）。",
                    level: .success
                )
                self.hasAutoSubmittedCurrentForm = true
                self.submitOnce(showScheduledNotice: false, source: "验证完成后继续提交")
            case .submitted(let message):
                self.finishCaptchaWatch(
                    message: "人机验证完成后问卷已提交：\(message)",
                    level: .success
                )
            case .closed(let message):
                self.finishCaptchaWatch(message: "问卷已不可提交：\(message)", level: .warning)
            case .captchaRequired, .failed, .loading:
                self.scheduleCaptchaWatchTick(watchID: watchID)
            }
        }
    }

    private func finishCaptchaWatch(message: String, level: AutomationLogLevel) {
        captchaWatchID = nil
        captchaWatchTicks = 0
        isAwaitingCaptchaCompletion = false
        appendLog(message, level: level, category: .security)
    }

    private func cancelCaptchaWatch() {
        captchaWatchID = nil
        captchaWatchTicks = 0
        captchaResumeCount = 0
        isAwaitingCaptchaCompletion = false
    }

    /// 用户自己确认验证已过时的手动入口，避免轮询判断不出来时卡住。
    func resumeAfterManualCaptcha() {
        guard isAwaitingCaptchaCompletion || state == .captchaRequired else { return }
        captchaWatchID = nil
        captchaWatchTicks = 0
        isAwaitingCaptchaCompletion = false
        captchaResumeCount += 1
        appendLog("已按你的确认继续提交（第 \(captchaResumeCount) 次）。", category: .security)
        hasAutoSubmittedCurrentForm = true
        submitOnce(showScheduledNotice: false, source: "手动继续提交")
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

    private static func integer(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

struct SurveyWebView: UIViewRepresentable {
    let controller: SurveyWebController
    let url: URL
    let rules: [FillRule]
    let autoFillOnLoad: Bool
    let autoSubmitAfterFill: Bool
    let submitDelaySeconds: Int
    let isSelected: Bool
    let initialLoadDelaySeconds: TimeInterval
    let officialAPIModeEnabled: Bool
    let requestHeaderProfiles: [RequestHeaderProfile]

    private static let sharedProcessPool = WKProcessPool()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Keep WJX draft-recovery state from carrying across app launches.
        configuration.websiteDataStore = .nonPersistent()
        configuration.processPool = Self.sharedProcessPool
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "parallelTest")
        configuration.userContentController.add(context.coordinator, name: "countdownAutoStart")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
#if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
#endif

        controller.webView = webView
        controller.setOfficialAPIMode(officialAPIModeEnabled)
        controller.setRequestHeaderProfiles(requestHeaderProfiles)
        controller.setPageSelected(isSelected)
        context.coordinator.updateRequestHeaderConfiguration(
            in: webView,
            profiles: requestHeaderProfiles,
            url: url
        )
        context.coordinator.loadedURL = url
        controller.prepareForNewSurvey(url)
        context.coordinator.scheduleSurveyLoad(in: webView, url: url)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = webView
        controller.setOfficialAPIMode(officialAPIModeEnabled)
        controller.setRequestHeaderProfiles(requestHeaderProfiles)
        controller.setPageSelected(isSelected)
        context.coordinator.updateRequestHeaderConfiguration(
            in: webView,
            profiles: requestHeaderProfiles,
            url: url
        )
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            controller.prepareForNewSurvey(url)
            context.coordinator.scheduleSurveyLoad(in: webView, url: url)
        } else if isSelected {
            context.coordinator.startPendingSurveyLoadImmediately(in: webView)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelScheduledWork()
        coordinator.parent.controller.shutdown()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "parallelTest")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "countdownAutoStart")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: SurveyWebView
        var loadedURL: URL?
        private var activeNavigation: WKNavigation?
        private var activeNavigationGeneration: Int?
        private var pendingSurveyLoadWorkItem: DispatchWorkItem?
        private var hasStartedScheduledLoad = false
        private var navigationWatchdogWorkItem: DispatchWorkItem?
        private var completedProgrammaticRequestID: UUID?
        private var installedRequestHeaderProfiles: [RequestHeaderProfile]?

        init(parent: SurveyWebView) {
            self.parent = parent
        }

        func updateRequestHeaderConfiguration(
            in webView: WKWebView,
            profiles: [RequestHeaderProfile],
            url: URL
        ) {
            let effectiveURL = webView.url ?? url
            webView.customUserAgent = RequestHeaderResolver.customUserAgent(
                for: effectiveURL,
                profiles: profiles
            )
            guard installedRequestHeaderProfiles != profiles else { return }
            let previouslyHadEnabledProfiles = installedRequestHeaderProfiles?
                .contains(where: \.isEnabled) == true
            installedRequestHeaderProfiles = profiles

            let userContentController = webView.configuration.userContentController
            userContentController.removeAllUserScripts()
            let hasEnabledProfiles = profiles.contains(where: \.isEnabled)
            if !hasEnabledProfiles {
                if previouslyHadEnabledProfiles,
                   let source = RequestHeaderResolver.injectionScript(profiles: []) {
                    webView.evaluateJavaScript(source)
                }
                return
            }
            guard let source = RequestHeaderResolver.injectionScript(profiles: profiles) else {
                return
            }
            userContentController.addUserScript(
                WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            webView.evaluateJavaScript(source)
        }

        func scheduleSurveyLoad(in webView: WKWebView, url: URL) {
            pendingSurveyLoadWorkItem?.cancel()
            pendingSurveyLoadWorkItem = nil
            hasStartedScheduledLoad = false

            let delay = parent.isSelected ? 0 : max(parent.initialLoadDelaySeconds, 0)
            guard delay > 0 else {
                beginScheduledSurveyLoad(in: webView, url: url)
                return
            }

            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.beginScheduledSurveyLoad(in: webView, url: url)
            }
            pendingSurveyLoadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func startPendingSurveyLoadImmediately(in webView: WKWebView) {
            guard !hasStartedScheduledLoad,
                  pendingSurveyLoadWorkItem != nil,
                  let loadedURL else { return }
            pendingSurveyLoadWorkItem?.cancel()
            pendingSurveyLoadWorkItem = nil
            beginScheduledSurveyLoad(in: webView, url: loadedURL)
        }

        func cancelScheduledWork() {
            pendingSurveyLoadWorkItem?.cancel()
            pendingSurveyLoadWorkItem = nil
            navigationWatchdogWorkItem?.cancel()
            navigationWatchdogWorkItem = nil
            completedProgrammaticRequestID = nil
        }

        private func beginScheduledSurveyLoad(in webView: WKWebView, url: URL) {
            guard !hasStartedScheduledLoad,
                  loadedURL == url,
                  parent.controller.webView === webView else { return }
            hasStartedScheduledLoad = true
            pendingSurveyLoadWorkItem = nil
            guard parent.controller.scheduleProgrammaticLoad(
                url: url,
                cachePolicy: .useProtocolCachePolicy
            ) else {
                parent.controller.handleLoadRequestRejected()
                return
            }
        }

        private func startNavigationWatchdog(
            for navigation: WKNavigation,
            generation: Int,
            in webView: WKWebView
        ) {
            navigationWatchdogWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.activeNavigation === navigation,
                      self.activeNavigationGeneration == generation,
                      webView.isLoading else { return }
                self.navigationWatchdogWorkItem = nil
                self.parent.controller.handleNavigationStalled(
                    navigationGeneration: generation
                )
            }
            navigationWatchdogWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
        }

        private func cancelNavigationWatchdog() {
            navigationWatchdogWorkItem?.cancel()
            navigationWatchdogWorkItem = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            updateRequestHeaderConfiguration(
                in: webView,
                profiles: parent.requestHeaderProfiles,
                url: webView.url ?? parent.url
            )
            parent.controller.handleProgrammaticNavigationStarted()
            if let completedProgrammaticRequestID,
               parent.controller.programmaticLoadRequestID == completedProgrammaticRequestID {
                parent.controller.finishProgrammaticLoad()
            }
            completedProgrammaticRequestID = nil
            if pendingSurveyLoadWorkItem != nil, webView.url == loadedURL {
                pendingSurveyLoadWorkItem?.cancel()
                pendingSurveyLoadWorkItem = nil
                hasStartedScheduledLoad = true
            }
            activeNavigation = navigation
            activeNavigationGeneration = parent.controller.handleNavigationStarted(in: webView)
            if parent.controller.hasProgrammaticLoadInFlight,
               let navigation,
               let generation = activeNavigationGeneration {
                startNavigationWatchdog(
                    for: navigation,
                    generation: generation,
                    in: webView
                )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation = navigation,
                  activeNavigation === navigation,
                  let generation = activeNavigationGeneration else { return }
            cancelNavigationWatchdog()
            activeNavigation = nil
            activeNavigationGeneration = nil
            completedProgrammaticRequestID = parent.controller.programmaticLoadRequestID
            updateRequestHeaderConfiguration(
                in: webView,
                profiles: parent.requestHeaderProfiles,
                url: webView.url ?? parent.url
            )
            parent.controller.handlePageLoaded(
                navigationGeneration: generation,
                defaultRules: parent.rules,
                autoFillOnLoad: parent.autoFillOnLoad,
                autoSubmitAfterFill: parent.autoSubmitAfterFill,
                submitDelaySeconds: parent.submitDelaySeconds
            )
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let navigation = navigation,
                  activeNavigation === navigation,
                  let generation = activeNavigationGeneration else { return }
            cancelNavigationWatchdog()
            activeNavigation = nil
            activeNavigationGeneration = nil
            completedProgrammaticRequestID = nil
            parent.controller.updateNavigationState(from: webView)
            parent.controller.handleNavigationFailure(
                error,
                navigationGeneration: generation
            )
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let navigation = navigation,
                  activeNavigation === navigation,
                  let generation = activeNavigationGeneration else { return }
            cancelNavigationWatchdog()
            activeNavigation = nil
            activeNavigationGeneration = nil
            completedProgrammaticRequestID = nil
            parent.controller.updateNavigationState(from: webView)
            parent.controller.handleNavigationFailure(
                error,
                navigationGeneration: generation
            )
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            cancelNavigationWatchdog()
            activeNavigation = nil
            activeNavigationGeneration = nil
            completedProgrammaticRequestID = nil
            parent.controller.handleWebContentProcessTerminated()
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

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            if Self.isDraftRecoveryPrompt(message) {
                parent.controller.handleDraftRecoveryPromptAutoCancelled()
                completionHandler(false)
                return
            }

            let alert = UIAlertController(
                title: nil,
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(
                UIAlertAction(title: "取消", style: .cancel) { _ in
                    completionHandler(false)
                }
            )
            alert.addAction(
                UIAlertAction(title: "确认", style: .default) { _ in
                    completionHandler(true)
                }
            )

            guard let presenter = Self.topViewController(
                from: webView.window?.rootViewController
            ) else {
                completionHandler(false)
                return
            }
            presenter.present(alert, animated: true)
        }

        private static func isDraftRecoveryPrompt(_ message: String) -> Bool {
            let compactMessage = message.filter { !$0.isWhitespace }
            return compactMessage.contains("回答了部分题目") &&
                compactMessage.contains("继续上次")
        }

        private static func topViewController(
            from rootViewController: UIViewController?
        ) -> UIViewController? {
            guard let rootViewController else { return nil }
            if let presented = rootViewController.presentedViewController {
                return topViewController(from: presented)
            }
            if let navigation = rootViewController as? UINavigationController {
                return topViewController(from: navigation.visibleViewController)
            }
            if let tab = rootViewController as? UITabBarController {
                return topViewController(from: tab.selectedViewController)
            }
            if let split = rootViewController as? UISplitViewController {
                return topViewController(from: split.viewControllers.last)
            }
            return rootViewController
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "parallelTest":
                parent.controller.handleParallelMessage(message.body)
            case "countdownAutoStart":
                guard message.frameInfo.isMainFrame else { return }
                parent.controller.handleCountdownAutoStartMessage(
                    message.body,
                    defaultRules: parent.rules,
                    autoFillOnLoad: parent.autoFillOnLoad,
                    autoSubmitAfterFill: parent.autoSubmitAfterFill,
                    submitDelaySeconds: parent.submitDelaySeconds
                )
            default:
                break
            }
        }
    }
}
