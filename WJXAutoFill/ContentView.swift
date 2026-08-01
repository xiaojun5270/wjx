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
                        statusHeader
                        Divider()
                        SurveyWebView(
                            controller: webController,
                            url: url,
                            rules: store.selectedPreset?.rules ?? [],
                            autoFillOnLoad: store.autoFillOnLoad,
                            autoSubmitAfterFill: store.autoSubmitAfterFill,
                            submitDelaySeconds: store.submitDelaySeconds
                        )
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        controlPanel
                    }
                } else {
                    invalidURLView
                }
            }
            .navigationTitle("问卷助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .sheet(isPresented: $showingRules) {
                RuleEditorView(store: store)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingLogs) {
                AutomationLogView(controller: webController)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(confirmationMessage)
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

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                webController.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!webController.canGoBack || webController.isBusy)
            .help("返回")
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                webController.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.surveyURL == nil || webController.isBusy)
            .help("重新加载")

            Button {
                showingLogs = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help("运行日志")

            Button {
                showingRules = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .disabled(webController.isBusy)
            .help("问卷与预设")
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                    Image(systemName: statusIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if webController.isFilling || webController.isWaitingToSubmit ||
                    webController.isSubmitting || webController.isQueueRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if case .ready(let count) = webController.state {
                    Text("\(count) 题")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if webController.isQueueRunning {
                ProgressView(value: webController.queueSnapshot.progress)
                    .tint(statusColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .animation(.easeInOut(duration: 0.2), value: webController.queueSnapshot.progress)
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            Divider()
            presetAndLogRow
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            Divider()

            if webController.isQueueRunning {
                runningQueueControls
            } else {
                singleControls
            }
        }
        .background(.regularMaterial)
    }

    private var presetAndLogRow: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("当前预设", selection: $store.selectedPresetID) {
                    ForEach(store.presets) { preset in
                        Label(
                            preset.name,
                            systemImage: preset.isQueueReady ? "checkmark.circle.fill" : "circle"
                        )
                        .tag(preset.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.text.rectangle")
                    Text(store.selectedPreset?.name ?? "选择预设")
                        .font(.subheadline.weight(.medium))
                    Text("\(store.selectedPreset?.completedFieldCount ?? 0)/3")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .disabled(webController.isBusy)

            Spacer(minLength: 4)

            Button {
                showingLogs = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: latestLogIcon)
                        .foregroundStyle(latestLogColor)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(webController.logs.last?.category.rawValue ?? "日志")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(webController.logs.last?.title ?? "暂无记录")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 190, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private var singleControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    if store.autoSubmitAfterFill {
                        webController.fillAndSubmit(
                            rules: store.selectedPreset?.rules ?? [],
                            submitDelaySeconds: store.submitDelaySeconds
                        )
                    } else {
                        webController.fill(rules: store.selectedPreset?.rules ?? [])
                    }
                } label: {
                    Label(fillButtonTitle, systemImage: "wand.and.stars")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!webController.canAttemptFill)

                Button {
                    confirmationAction = .singleSubmit
                    showingConfirmation = true
                } label: {
                    Label("仅提交", systemImage: "paperplane.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!webController.canAttemptSubmit)
            }

            Button {
                confirmationAction = .testQueue
                showingConfirmation = true
            } label: {
                HStack {
                    Label("提交 10 组预设", systemImage: "rectangle.3.group.fill")
                    Spacer()
                    Text(batchReadinessText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!canStartQueue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var runningQueueControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 14) {
                queueMetric("成功", value: webController.queueSnapshot.succeeded, color: .green)
                queueMetric("失败", value: webController.queueSnapshot.failed, color: .red)
                queueMetric("运行中", value: webController.queueSnapshot.active, color: .blue)
                Spacer(minLength: 4)
                Text("\(webController.queueSnapshot.completed)/\(webController.queueSnapshot.total)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            Button(role: .destructive) {
                webController.stopTestQueue()
            } label: {
                Label("停止批量任务", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func queueMetric(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(value)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var invalidURLView: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("问卷地址无效")
                .font(.headline)
            Text("请输入 wjx.cn 的 HTTPS 问卷地址")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showingRules = true
            } label: {
                Label("打开设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmationAction {
        case .singleSubmit:
            Button("提交当前页面", role: .destructive) {
                webController.submitOnce()
            }
        case .testQueue:
            Button("启动 10 组任务", role: .destructive) {
                guard let url = store.surveyURL else { return }
                webController.startParallelTest(
                    presets: store.queuePresets,
                    surveyURL: url,
                    concurrency: store.parallelConcurrency,
                    submitDelaySeconds: store.submitDelaySeconds
                )
            }
        }
        Button("取消", role: .cancel) {}
    }

    private var confirmationTitle: String {
        switch confirmationAction {
        case .singleSubmit: return "确认提交"
        case .testQueue: return "确认批量提交"
        }
    }

    private var confirmationMessage: String {
        switch confirmationAction {
        case .singleSubmit:
            return "将提交当前页面中的答案，仅执行一次。"
        case .testQueue:
            return "10 个页面并行填写，提交时严格逐组执行，每组间隔 \(store.submitDelaySeconds) 秒。"
        }
    }

    private var fillButtonTitle: String {
        if webController.isFilling { return "填写中" }
        if webController.isWaitingToSubmit { return "等待提交" }
        if webController.isSubmitting { return "提交中" }
        return store.autoSubmitAfterFill ? "填写并提交" : "自动填写"
    }

    private var batchReadinessText: String {
        store.parallelValidationMessage ?? "已就绪"
    }

    private var canStartQueue: Bool {
        guard store.isParallelReady, store.surveyURL != nil, !webController.isBusy else { return false }
        switch webController.state {
        case .ready(_), .submitted(_): return true
        default: return false
        }
    }

    private var statusTitle: String {
        if webController.isQueueRunning { return "批量任务进行中" }
        if webController.isFilling { return "正在填写当前预设" }
        if webController.isWaitingToSubmit { return "等待自动提交" }
        if webController.isSubmitting { return "正在提交问卷" }

        switch webController.queueState {
        case .completed: return "批量任务已完成"
        case .stopped: return "批量任务已停止"
        case .idle, .running: break
        }

        switch webController.state {
        case .loading: return "正在加载问卷"
        case .ready: return "问卷已就绪"
        case .submitted: return "提交已完成"
        case .closed: return "问卷不可填写"
        case .captchaRequired: return "需要安全验证"
        case .failed: return "页面加载失败"
        }
    }

    private var statusDetail: String {
        if webController.isQueueRunning {
            let snapshot = webController.queueSnapshot
            return "已完成 \(snapshot.completed)/\(snapshot.total) · \(snapshot.detail)"
        }
        if webController.isFilling {
            return "使用 \(store.selectedPreset?.name ?? "当前预设")"
        }
        if webController.isWaitingToSubmit { return "填写完成，\(store.submitDelaySeconds) 秒后提交" }
        if webController.isSubmitting { return "等待问卷星返回结果" }

        switch webController.queueState {
        case .completed:
            let snapshot = webController.queueSnapshot
            return "成功 \(snapshot.succeeded) · 失败 \(snapshot.failed) · 共 \(snapshot.total)"
        case .stopped(let message):
            return message
        case .idle, .running:
            break
        }

        switch webController.state {
        case .loading:
            return store.surveyURL?.host ?? "正在连接"
        case .ready(let count):
            return "检测到 \(count) 道可填写题目"
        case .submitted(let message), .closed(let message), .failed(let message):
            return message
        case .captchaRequired:
            return "请在当前页面完成验证后继续"
        }
    }

    private var statusIcon: String {
        if webController.isQueueRunning { return "arrow.triangle.2.circlepath" }
        if webController.isFilling { return "wand.and.stars" }
        if webController.isWaitingToSubmit { return "timer" }
        if webController.isSubmitting { return "paperplane.fill" }

        switch webController.queueState {
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .idle, .running: break
        }

        switch webController.state {
        case .loading: return "hourglass"
        case .ready: return "checkmark.circle.fill"
        case .submitted: return "checkmark.seal.fill"
        case .closed: return "xmark.octagon.fill"
        case .captchaRequired: return "person.badge.key.fill"
        case .failed: return "wifi.exclamationmark"
        }
    }

    private var statusColor: Color {
        if webController.isQueueRunning || webController.isFilling ||
            webController.isWaitingToSubmit || webController.isSubmitting {
            return .blue
        }

        switch webController.queueState {
        case .completed:
            return webController.queueSnapshot.failed == 0 ? .green : .orange
        case .stopped: return .orange
        case .idle, .running: break
        }

        switch webController.state {
        case .loading: return .secondary
        case .ready, .submitted: return .green
        case .closed, .failed: return .red
        case .captchaRequired: return .orange
        }
    }

    private var latestLogColor: Color {
        switch webController.logs.last?.level {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info, .none: return .blue
        }
    }

    private var latestLogIcon: String {
        switch webController.logs.last?.level {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info, .none: return "info.circle.fill"
        }
    }
}

private struct AutomationLogView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case success = "成功"
        case warning = "警告"
        case error = "失败"

        var id: String { rawValue }
    }

    @ObservedObject var controller: SurveyWebController
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                logSummary

                Picker("日志级别", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if filteredLogs.isEmpty {
                    emptyLogView
                } else {
                    List(filteredLogs.reversed()) { entry in
                        logRow(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索日志")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: controller.logExportText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(controller.logs.isEmpty)
                    .help("导出日志")

                    Button(role: .destructive) {
                        controller.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(controller.logs.isEmpty)
                    .help("清空日志")
                }
            }
        }
    }

    private var logSummary: some View {
        HStack(spacing: 0) {
            summaryMetric("总计", count: controller.logs.count, color: .primary)
            summaryMetric("成功", count: count(for: .success), color: .green)
            summaryMetric("警告", count: count(for: .warning), color: .orange)
            summaryMetric("失败", count: count(for: .error), color: .red)
        }
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func summaryMetric(_ title: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyLogView: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "doc.text" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "暂无日志" : "没有匹配的日志")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logRow(_ entry: AutomationLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: entry.level))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: entry.level))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(entry.category.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(for: entry.level))
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var filteredLogs: [AutomationLogEntry] {
        controller.logs.filter { entry in
            let matchesLevel: Bool
            switch filter {
            case .all: matchesLevel = true
            case .success: matchesLevel = entry.level == .success
            case .warning: matchesLevel = entry.level == .warning
            case .error: matchesLevel = entry.level == .error
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty ||
                entry.message.localizedCaseInsensitiveContains(query) ||
                entry.category.rawValue.localizedCaseInsensitiveContains(query)
            return matchesLevel && matchesSearch
        }
    }

    private func count(for level: AutomationLogLevel) -> Int {
        controller.logs.filter { $0.level == level }.count
    }

    private func iconName(for level: AutomationLogLevel) -> String {
        switch level {
        case .info: return "info.circle.fill"
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
