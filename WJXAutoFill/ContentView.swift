import SwiftUI

struct ContentView: View {
    private enum ConfirmationAction {
        case singleSubmit
        case testQueue
    }

    @StateObject private var store = RuleStore()
    @StateObject private var webController = SurveyWebController()
    @State private var showingRules = false
    @State private var showingLogs = false
    @State private var showingConfirmation = false
    @State private var confirmationAction: ConfirmationAction = .singleSubmit

    var body: some View {
        NavigationStack {
            Group {
                if let url = store.surveyURL {
                    VStack(spacing: 0) {
                        statusBar
                        logBar
                        SurveyWebView(
                            controller: webController,
                            url: url,
                            rules: store.selectedPreset?.rules ?? [],
                            autoFillOnLoad: store.autoFillOnLoad,
                            autoSubmitAfterFill: store.autoSubmitAfterFill
                        )
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        actionBar
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("问卷地址无效")
                            .font(.title3.weight(.semibold))
                        Text("请在规则设置中输入 wjx.cn 的 HTTPS 问卷地址。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                }
            }
            .navigationTitle("问卷助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        webController.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(
                        !webController.canGoBack || webController.isQueueRunning ||
                        webController.isFilling || webController.isSubmitting
                    )
                    .help("返回上一页")
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showingLogs = true
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .help("运行日志")

                    Button {
                        webController.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(
                        store.surveyURL == nil || webController.isQueueRunning ||
                        webController.isFilling || webController.isSubmitting
                    )

                    Button {
                        showingRules = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .disabled(webController.isQueueRunning)
                }
            }
            .sheet(isPresented: $showingRules) {
                RuleEditorView(store: store)
            }
            .sheet(isPresented: $showingLogs) {
                AutomationLogView(controller: webController)
            }
            .confirmationDialog("确认操作", isPresented: $showingConfirmation, titleVisibility: .visible) {
                switch confirmationAction {
                case .singleSubmit:
                    Button("确认单次提交", role: .destructive) {
                        webController.submitOnce()
                    }
                case .testQueue:
                    Button("启动 10 组预设的后台并行提交", role: .destructive) {
                        guard let url = store.surveyURL else { return }
                        webController.startParallelTest(
                            presets: store.queuePresets,
                            surveyURL: url,
                            concurrency: store.parallelConcurrency
                        )
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                switch confirmationAction {
                case .singleSubmit:
                    Text("请先核对页面中的所有答案。此操作只触发一次提交。")
                case .testQueue:
                    Text("应用会在隐藏页面中同时启动 10 个填写和提交任务。请仅用于你获授权的测试问卷。")
                }
            }
            .alert(item: $webController.notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
            Text(statusText)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(statusColor.opacity(0.10))
    }

    private var logBar: some View {
        Button {
            showingLogs = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                Text(webController.logs.last?.message ?? "等待运行日志")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .font(.caption)
            .foregroundStyle(logColor(webController.logs.last?.level))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var actionBar: some View {
        VStack(spacing: 9) {
            if webController.isQueueRunning {
                HStack {
                    ProgressView()
                    Text(queueProgressText)
                        .font(.footnote)
                    Spacer()
                    Button("停止", role: .destructive) {
                        webController.stopTestQueue()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        if store.autoSubmitAfterFill {
                            webController.fillAndSubmit(rules: store.selectedPreset?.rules ?? [])
                        } else {
                            webController.fill(rules: store.selectedPreset?.rules ?? [])
                        }
                    } label: {
                        Label(
                            store.autoSubmitAfterFill ? "填写并提交" : "自动填写",
                            systemImage: "wand.and.stars"
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(webController.isFilling || webController.isSubmitting)

                    Button {
                        confirmationAction = .singleSubmit
                        showingConfirmation = true
                    } label: {
                        Label(webController.isSubmitting ? "提交中" : "核对并提交", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!webController.canAttemptSubmit)
                }

                Button {
                    confirmationAction = .testQueue
                    showingConfirmation = true
                } label: {
                    Label("同时提交 10 组预设（已填 \(store.queuePresets.count)/10）", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canStartQueue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var statusText: String {
        switch webController.queueState {
        case .running(let current, let total, let presetName):
            return "后台并行 \(current)/\(total)：\(presetName)"
        case .completed(let total):
            return "后台并行测试完成：成功 \(total) 个预设"
        case .stopped(let message):
            return "后台并行测试已停止：\(message)"
        case .idle:
            break
        }

        switch webController.state {
        case .loading:
            return "正在加载并检查问卷…"
        case .ready(let count):
            return count > 0 ? "页面可填写，检测到 \(count) 道题" : "页面已加载，尚未检测到可填写题目"
        case .submitted(let message):
            return "提交完成：\(message)"
        case .closed(let message):
            return "问卷不可填写：\(message)"
        case .captchaRequired:
            return "需要在页面中手动完成人机验证"
        case .failed(let message):
            return "页面加载失败：\(message)"
        }
    }

    private var statusIcon: String {
        switch webController.queueState {
        case .running(_, _, _): return "arrow.triangle.2.circlepath"
        case .completed(_): return "checkmark.circle"
        case .stopped(_): return "stop.circle"
        case .idle: break
        }

        switch webController.state {
        case .loading: return "hourglass"
        case .ready(_), .submitted(_): return "checkmark.circle"
        case .closed(_): return "xmark.octagon"
        case .captchaRequired: return "person.badge.key"
        case .failed(_): return "wifi.exclamationmark"
        }
    }

    private var statusColor: Color {
        switch webController.queueState {
        case .running(_, _, _): return .blue
        case .completed(_): return .green
        case .stopped(_): return .red
        case .idle: break
        }

        switch webController.state {
        case .loading: return .secondary
        case .ready(_), .submitted(_): return .green
        case .closed(_), .failed(_): return .red
        case .captchaRequired: return .orange
        }
    }

    private var canStartQueue: Bool {
        guard store.isParallelReady, store.surveyURL != nil,
              !webController.isFilling, !webController.isSubmitting else { return false }
        switch webController.state {
        case .ready(_), .submitted(_):
            return true
        default:
            return false
        }
    }

    private func logColor(_ level: AutomationLogLevel?) -> Color {
        switch level {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info, .none: return .secondary
        }
    }

    private var queueProgressText: String {
        if case .running(let current, let total, let presetName) = webController.queueState {
            return "\(current)/\(total) · \(presetName)"
        }
        return "后台并行测试运行中"
    }
}

private struct AutomationLogView: View {
    @ObservedObject var controller: SurveyWebController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.logs.isEmpty {
                    Text("暂无运行日志")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(controller.logs.reversed())) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: iconName(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.message)
                                    .font(.subheadline)
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空", role: .destructive) {
                        controller.clearLogs()
                    }
                    .disabled(controller.logs.isEmpty)
                }
            }
        }
    }

    private func iconName(for level: AutomationLogLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for level: AutomationLogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    ContentView()
}
