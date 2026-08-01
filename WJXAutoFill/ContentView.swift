import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var store: RuleStore
    @StateObject private var workspace: SurveyWorkspace
    @State private var showingCompactSidebar = false
    @State private var pagePendingClose: UUID?

    init() {
        let store = RuleStore()
        _store = StateObject(wrappedValue: store)
        _workspace = StateObject(
            wrappedValue: SurveyWorkspace(
                defaultURLString: store.surveyURLString,
                defaultPresetID: store.selectedPresetID,
                autoFillOnLoad: store.autoFillOnLoad,
                autoSubmitAfterFill: store.autoSubmitAfterFill,
                submitDelaySeconds: store.submitDelaySeconds
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let usesPersistentSidebar = proxy.size.width >= 700

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if usesPersistentSidebar {
                        pageSidebar(isCompact: false)
                            .frame(width: 250)
                        Divider()
                    }

                    pageStack(showsSidebarButton: !usesPersistentSidebar)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !usesPersistentSidebar, showingCompactSidebar {
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .onTapGesture { showingCompactSidebar = false }

                    pageSidebar(isCompact: true)
                        .frame(width: min(proxy.size.width * 0.82, 310))
                        .background(Color(uiColor: .systemGroupedBackground))
                        .transition(.move(edge: .leading))
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 8)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showingCompactSidebar)
            .onChange(of: usesPersistentSidebar) { isPersistent in
                if isPersistent { showingCompactSidebar = false }
            }
        }
        .confirmationDialog(
            "关闭页面？",
            isPresented: Binding(
                get: { pagePendingClose != nil },
                set: { if !$0 { pagePendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("关闭页面", role: .destructive) {
                guard let pagePendingClose else { return }
                workspace.closePage(pagePendingClose)
                self.pagePendingClose = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该页面的定时、填写和后台任务将停止。其他页面不受影响。")
        }
    }

    private func pageStack(showsSidebarButton: Bool) -> some View {
        ZStack {
            ForEach(workspace.pages) { page in
                SurveyPageView(
                    session: page,
                    store: store,
                    isSelected: workspace.selectedPageID == page.id,
                    showsSidebarButton: showsSidebarButton,
                    onShowSidebar: { showingCompactSidebar = true }
                )
                .opacity(workspace.selectedPageID == page.id ? 1 : 0)
                .allowsHitTesting(workspace.selectedPageID == page.id)
                .accessibilityHidden(workspace.selectedPageID != page.id)
                .zIndex(workspace.selectedPageID == page.id ? 1 : 0)
            }
        }
    }

    private func pageSidebar(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("页面")
                    .font(.title3.weight(.semibold))
                Spacer()

                Menu {
                    Button {
                        addPage(copyCurrent: false, closesSidebar: isCompact)
                    } label: {
                        Label("新建页面", systemImage: "plus")
                    }

                    Button {
                        addPage(copyCurrent: true, closesSidebar: isCompact)
                    } label: {
                        Label("复制当前页面", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                }
                .disabled(!workspace.canAddPage)
                .help("添加页面")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.pages) { page in
                        SurveyPageSidebarRow(
                            page: page,
                            isSelected: workspace.selectedPageID == page.id,
                            canClose: workspace.pages.count > 1,
                            onSelect: {
                                workspace.selectedPageID = page.id
                                if isCompact { showingCompactSidebar = false }
                            },
                            onClose: { pagePendingClose = page.id }
                        )
                    }
                }
                .padding(8)
            }

            Divider()
            HStack {
                Image(systemName: "rectangle.stack")
                Text("\(workspace.pages.count) / \(SurveyWorkspace.maximumPageCount)")
                    .font(.caption.monospacedDigit())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func addPage(copyCurrent: Bool, closesSidebar: Bool) {
        if copyCurrent {
            workspace.duplicateSelectedPage()
        } else {
            workspace.addPage(
                defaultURLString: store.surveyURLString,
                defaultPresetID: store.selectedPresetID,
                autoFillOnLoad: store.autoFillOnLoad,
                autoSubmitAfterFill: store.autoSubmitAfterFill,
                submitDelaySeconds: store.submitDelaySeconds
            )
        }
        if closesSidebar { showingCompactSidebar = false }
    }
}

private struct SurveyPageSidebarRow: View {
    @ObservedObject var page: SurveyPageSession
    @ObservedObject private var controller: SurveyWebController
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    init(
        page: SurveyPageSession,
        isSelected: Bool,
        canClose: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _page = ObservedObject(wrappedValue: page)
        _controller = ObservedObject(wrappedValue: page.controller)
        self.isSelected = isSelected
        self.canClose = canClose
        self.onSelect = onSelect
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(page.surveyURL?.host ?? "地址未设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭\(page.title)")
                .help("关闭页面")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var statusColor: Color {
        if controller.scheduledBatchTarget != nil { return .orange }
        if controller.isBusy { return .blue }
        switch controller.queueState {
        case .completed:
            return controller.queueSnapshot.failed == 0 ? .green : .orange
        case .stopped:
            return .orange
        case .idle, .running:
            break
        }
        switch controller.state {
        case .ready, .submitted: return .green
        case .captchaRequired: return .orange
        case .closed, .failed: return .red
        case .loading: return .secondary
        }
    }
}

private struct SurveyPageView: View {
    private enum ConfirmationAction {
        case singleSubmit
        case prepareBatch
        case scheduleBatch
        case submitPreparedBatch
    }

    @ObservedObject var session: SurveyPageSession
    @ObservedObject var store: RuleStore
    @ObservedObject private var webController: SurveyWebController
    let isSelected: Bool
    let showsSidebarButton: Bool
    let onShowSidebar: () -> Void
    @State private var showingRules = false
    @State private var showingLogs = false
    @State private var showingConfirmation = false
    @State private var confirmationAction: ConfirmationAction = .singleSubmit

    init(
        session: SurveyPageSession,
        store: RuleStore,
        isSelected: Bool,
        showsSidebarButton: Bool,
        onShowSidebar: @escaping () -> Void
    ) {
        _session = ObservedObject(wrappedValue: session)
        _store = ObservedObject(wrappedValue: store)
        _webController = ObservedObject(wrappedValue: session.controller)
        self.isSelected = isSelected
        self.showsSidebarButton = showsSidebarButton
        self.onShowSidebar = onShowSidebar
    }

    var body: some View {
        NavigationStack {
            Group {
                if let url = session.surveyURL {
                    VStack(spacing: 0) {
                        statusHeader
                        Divider()
                        SurveyWebView(
                            controller: webController,
                            url: url,
                            rules: selectedPreset?.rules ?? [],
                            autoFillOnLoad: session.autoFillOnLoad,
                            autoSubmitAfterFill: session.autoSubmitAfterFill,
                            submitDelaySeconds: session.submitDelaySeconds
                        )
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        controlPanel
                    }
                } else {
                    invalidURLView
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { browserToolbar }
            .sheet(isPresented: $showingRules) {
                RuleEditorView(
                    store: store,
                    surveyURLString: Binding(
                        get: { session.surveyURLString },
                        set: {
                            session.surveyURLString = $0
                            store.surveyURLString = $0
                        }
                    ),
                    selectedPresetID: selectedPresetIDBinding,
                    autoFillOnLoad: autoFillOnLoadBinding,
                    autoSubmitAfterFill: autoSubmitAfterFillBinding,
                    submitDelaySeconds: submitDelaySecondsBinding
                )
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
            .alert(item: visibleNoticeBinding) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
        }
    }

    private var visibleNoticeBinding: Binding<UserNotice?> {
        Binding(
            get: { isSelected ? webController.notice : nil },
            set: { webController.notice = $0 }
        )
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            if showsSidebarButton {
                Button(action: onShowSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .help("页面菜单")
            }

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
            .disabled(session.surveyURL == nil || webController.isBusy)
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

            if webController.scheduledBatchTarget != nil {
                scheduledBatchControls
            } else if webController.isScheduledBatchRefreshing {
                scheduledRefreshControls
            } else if webController.isQueueRunning {
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
                Picker("当前预设", selection: selectedPresetIDBinding) {
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
                    Text(selectedPreset?.name ?? "选择预设")
                        .font(.subheadline.weight(.medium))
                    Text("\(selectedPreset?.completedFieldCount ?? 0)/3")
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
                    if session.autoSubmitAfterFill {
                        webController.fillAndSubmit(
                            rules: selectedPreset?.rules ?? [],
                            submitDelaySeconds: session.submitDelaySeconds
                        )
                    } else {
                        webController.fill(rules: selectedPreset?.rules ?? [])
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

            HStack(spacing: 10) {
                Button {
                    confirmationAction = .prepareBatch
                    showingConfirmation = true
                } label: {
                    Label("同步填写 10 组", systemImage: "rectangle.3.group.fill")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canStartQueue)

                Button {
                    confirmationAction = .scheduleBatch
                    showingConfirmation = true
                } label: {
                    Label("下个整点执行", systemImage: "clock")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canScheduleQueue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scheduledBatchControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Label("等待整点", systemImage: "clock.fill")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let target = webController.scheduledBatchTarget {
                    Text(target.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(formattedBatchCountdown)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            Button(role: .destructive) {
                webController.cancelScheduledBatch()
            } label: {
                Label("取消整点任务", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scheduledRefreshControls: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("整点刷新中")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("随后同步填写 10 组")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var runningQueueControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 14) {
                if webController.isBatchSubmitting {
                    queueMetric("成功", value: webController.queueSnapshot.succeeded, color: .green)
                    queueMetric("失败", value: webController.queueSnapshot.failed, color: .red)
                    queueMetric("待返回", value: webController.queueSnapshot.active, color: .blue)
                } else {
                    queueMetric("已填写", value: webController.batchPreparedCount, color: .green)
                    queueMetric(
                        "待填写",
                        value: max(webController.queueSnapshot.total - webController.batchPreparedCount, 0),
                        color: .blue
                    )
                }
                Spacer(minLength: 4)
                Text("\(webController.isBatchSubmitting ? webController.queueSnapshot.completed : webController.batchPreparedCount)/\(webController.queueSnapshot.total)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            if webController.isBatchReadyToSubmit {
                Button {
                    confirmationAction = .submitPreparedBatch
                    showingConfirmation = true
                } label: {
                    Label("同步提交 10 组", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
        case .prepareBatch:
            Button("开始同步填写") {
                guard let url = session.surveyURL else { return }
                webController.startParallelTest(
                    presets: store.queuePresets,
                    surveyURL: url
                )
            }
        case .scheduleBatch:
            Button("设置整点任务") {
                guard let url = session.surveyURL else { return }
                webController.scheduleBatchAtNextHour(
                    presets: store.queuePresets,
                    surveyURL: url
                )
            }
        case .submitPreparedBatch:
            Button("同步提交 10 组", role: .destructive) {
                webController.submitPreparedBatch()
            }
        }
        Button("取消", role: .cancel) {}
    }

    private var confirmationTitle: String {
        switch confirmationAction {
        case .singleSubmit: return "确认提交"
        case .prepareBatch: return "同步填写 10 组"
        case .scheduleBatch: return "确认整点执行"
        case .submitPreparedBatch: return "确认同步提交"
        }
    }

    private var confirmationMessage: String {
        switch confirmationAction {
        case .singleSubmit:
            return "将提交当前页面中的答案，仅执行一次。"
        case .prepareBatch:
            return "将同时打开并填写 10 个隐藏页面，填写完成后不会自动提交。"
        case .scheduleBatch:
            return "将在 \(nextWholeHour.formatted(date: .abbreviated, time: .shortened)) 强制刷新问卷并同步填写 10 组。请保持 App 在前台。"
        case .submitPreparedBatch:
            return "将同时触发 10 组提交。此操作更容易触发问卷星安全验证，提交后无法撤回。"
        }
    }

    private var fillButtonTitle: String {
        if webController.isFilling { return "填写中" }
        if webController.isWaitingToSubmit { return "等待提交" }
        if webController.isSubmitting { return "提交中" }
        return session.autoSubmitAfterFill ? "填写并提交" : "自动填写"
    }

    private var nextWholeHour: Date {
        let now = Date()
        let hourStart = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        return Calendar.current.date(byAdding: .hour, value: 1, to: hourStart)
            ?? now.addingTimeInterval(3_600)
    }

    private var selectedPreset: SubmissionPreset? {
        store.presets.first { $0.id == session.selectedPresetID } ?? store.presets.first
    }

    private var selectedPresetIDBinding: Binding<UUID> {
        Binding(
            get: { session.selectedPresetID },
            set: {
                session.selectedPresetID = $0
                store.selectedPresetID = $0
            }
        )
    }

    private var autoFillOnLoadBinding: Binding<Bool> {
        Binding(
            get: { session.autoFillOnLoad },
            set: {
                session.autoFillOnLoad = $0
                store.autoFillOnLoad = $0
            }
        )
    }

    private var autoSubmitAfterFillBinding: Binding<Bool> {
        Binding(
            get: { session.autoSubmitAfterFill },
            set: {
                session.autoSubmitAfterFill = $0
                store.autoSubmitAfterFill = $0
            }
        )
    }

    private var submitDelaySecondsBinding: Binding<Int> {
        Binding(
            get: { session.submitDelaySeconds },
            set: {
                let value = min(max($0, 0), RuleStore.maximumSubmitDelaySeconds)
                session.submitDelaySeconds = value
                store.setSubmitDelaySeconds(value)
            }
        )
    }

    private var formattedBatchCountdown: String {
        let seconds = max(webController.batchScheduleRemainingSeconds, 0)
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private var canStartQueue: Bool {
        guard store.isParallelReady, session.surveyURL != nil, !webController.isBusy else { return false }
        switch webController.state {
        case .ready(_), .submitted(_): return true
        default: return false
        }
    }

    private var canScheduleQueue: Bool {
        guard store.isParallelReady, session.surveyURL != nil, !webController.isBusy else { return false }
        if case .loading = webController.state { return false }
        return true
    }

    private var statusTitle: String {
        if webController.scheduledBatchTarget != nil { return "等待活动整点" }
        if webController.isScheduledBatchRefreshing { return "正在整点刷新" }
        if webController.isBatchReadyToSubmit { return "等待手动提交" }
        if webController.isBatchSubmitting { return "10 组正在同步提交" }
        if webController.isQueueRunning { return "正在同步填写" }
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
        if let target = webController.scheduledBatchTarget {
            return "\(target.formatted(date: .abbreviated, time: .shortened)) · \(formattedBatchCountdown)"
        }
        if webController.isScheduledBatchRefreshing {
            return "刷新完成后自动同步填写 10 组"
        }
        if webController.isQueueRunning {
            let snapshot = webController.queueSnapshot
            if webController.isBatchReadyToSubmit {
                return "已填写 \(webController.batchPreparedCount)/\(snapshot.total) · 点击下方按钮提交"
            }
            if webController.isBatchSubmitting {
                return "已返回 \(snapshot.completed)/\(snapshot.total) · \(snapshot.detail)"
            }
            return "已填写 \(webController.batchPreparedCount)/\(snapshot.total) · \(snapshot.detail)"
        }
        if webController.isFilling {
            return "使用 \(selectedPreset?.name ?? "当前预设")"
        }
        if webController.isWaitingToSubmit { return "填写完成，\(session.submitDelaySeconds) 秒后提交" }
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
            return session.surveyURL?.host ?? "正在连接"
        case .ready(let count):
            return "检测到 \(count) 道可填写题目"
        case .submitted(let message), .closed(let message), .failed(let message):
            return message
        case .captchaRequired:
            return "请在当前页面完成验证后继续"
        }
    }

    private var statusIcon: String {
        if webController.scheduledBatchTarget != nil { return "clock.fill" }
        if webController.isScheduledBatchRefreshing { return "arrow.clockwise" }
        if webController.isBatchReadyToSubmit { return "hand.tap.fill" }
        if webController.isBatchSubmitting { return "paperplane.fill" }
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
        if webController.scheduledBatchTarget != nil { return .orange }
        if webController.isScheduledBatchRefreshing { return .blue }
        if webController.isBatchReadyToSubmit { return .green }
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
