import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var store: RuleStore
    @StateObject private var workspace: SurveyWorkspace
    @State private var workspaceNotice: UserNotice?

    init() {
        let store = RuleStore()
        _store = StateObject(wrappedValue: store)
        _workspace = StateObject(
            wrappedValue: SurveyWorkspace(
                defaultURLString: store.surveyURLString,
                defaultPresetID: store.selectedPresetID,
                presetIDs: store.presets.map(\.id),
                autoFillOnLoad: store.autoFillOnLoad,
                autoSubmitAfterFill: store.autoSubmitAfterFill,
                submitDelaySeconds: store.submitDelaySeconds
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 700
            let compactWidth = min(max(proxy.size.width * 0.23, 88), 104)

            HStack(spacing: 0) {
                pageSidebar(isCompact: isCompact)
                    .frame(width: isCompact ? compactWidth : 210)
                Divider()
                pageStack()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(item: $workspaceNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func pageStack() -> some View {
        ZStack {
            ForEach(workspace.pages) { page in
                SurveyPageView(
                    session: page,
                    store: store,
                    isSelected: workspace.selectedPageID == page.id,
                    hasNextPage: workspace.hasNextPage(after: page.id),
                    onSynchronizeSurveyURL: { value in
                        workspace.synchronizeSurveyURL(value)
                    },
                    onNextPage: {
                        workspace.selectNextPage(after: page.id)
                    },
                    onSubmissionCompleted: {
                        workspace.selectNextPage(after: page.id)
                    }
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
            HStack(spacing: isCompact ? 4 : 8) {
                if !isCompact {
                    Text("页面")
                        .font(.title3.weight(.semibold))
                    Spacer()
                } else {
                    Spacer(minLength: 0)
                }

                Button(action: reloadAllPages) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: isCompact ? 24 : 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新所有页面")
                .help("刷新所有已打开页面")

                Button(action: addPage) {
                    Image(systemName: "plus")
                        .frame(width: isCompact ? 24 : 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新增页面")
                .help("新增页面并沿用当前配置")

                if isCompact {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, isCompact ? 8 : 12)
            .padding(.vertical, 9)

            Divider()

            List {
                ForEach(workspace.pages) { page in
                    SurveyPageSidebarRow(
                        page: page,
                        presetName: presetName(for: page),
                        isCompact: isCompact,
                        isSelected: workspace.selectedPageID == page.id,
                        onSelect: {
                            workspace.selectedPageID = page.id
                        }
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: 4,
                            leading: isCompact ? 6 : 9,
                            bottom: 4,
                            trailing: isCompact ? 6 : 9
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if workspace.pages.count > 1 {
                            Button(role: .destructive) {
                                workspace.closePage(page.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, isCompact ? 54 : 58)

            Divider()
            HStack {
                Image(systemName: "rectangle.stack")
                Text("\(workspace.pages.count) 个")
                    .font(.caption.monospacedDigit())
                if !isCompact { Spacer() }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .padding(.horizontal, isCompact ? 6 : 12)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func addPage() {
        workspace.duplicateSelectedPage(presetIDs: store.presets.map(\.id))
    }

    private func reloadAllPages() {
        let busyPages = workspace.pages.filter { $0.controller.isBusy }
        guard busyPages.isEmpty else {
            workspaceNotice = UserNotice(
                title: "暂时无法刷新全部",
                message: "请先结束正在填写、提交或等待整点的页面，再刷新所有页面。"
            )
            return
        }

        let reloadablePages = workspace.pages.filter { $0.surveyURL != nil }
        guard !reloadablePages.isEmpty else {
            workspaceNotice = UserNotice(
                title: "没有可刷新页面",
                message: "请先为页面设置有效的问卷地址。"
            )
            return
        }

        for (index, page) in reloadablePages.enumerated() {
            guard let url = page.surveyURL else { continue }
            let delay = Double(index) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                _ = page.controller.reopenSurvey(url)
            }
        }

        if reloadablePages.count != workspace.pages.count {
            workspaceNotice = UserNotice(
                title: "部分页面已刷新",
                message: "已安排刷新 \(reloadablePages.count) 个页面；尚未加载或地址无效的页面已跳过。"
            )
        }
    }

    private func presetName(for page: SurveyPageSession) -> String {
        store.presets.first { $0.id == page.selectedPresetID }?.name ?? "未选预设"
    }
}

private struct SurveyPageSidebarRow: View {
    @ObservedObject var page: SurveyPageSession
    @ObservedObject private var controller: SurveyWebController
    let presetName: String
    let isCompact: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    init(
        page: SurveyPageSession,
        presetName: String,
        isCompact: Bool,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        _page = ObservedObject(wrappedValue: page)
        _controller = ObservedObject(wrappedValue: page.controller)
        self.presetName = presetName
        self.isCompact = isCompact
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: isCompact ? 7 : 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.18))
                    .frame(width: isCompact ? 15 : 17, height: isCompact ? 15 : 17)
                Circle()
                    .fill(statusColor)
                    .frame(width: isCompact ? 7 : 8, height: isCompact ? 7 : 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(isCompact ? "页 \(page.pageNumber)" : page.title)
                    .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(isCompact ? presetName : "\(presetName) · \(page.surveyURL?.host ?? "地址未设置")")
                    .font(isCompact ? .caption2 : .caption)
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.72) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: isCompact ? 1 : 4)

            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 11)
        .padding(.vertical, isCompact ? 7 : 8)
        .frame(minHeight: isCompact ? 54 : 58)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.15)
                        : Color(uiColor: .secondarySystemGroupedBackground)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.52)
                        : Color.primary.opacity(0.07),
                    lineWidth: isSelected ? 1.2 : 0.6
                )
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: isCompact ? 30 : 34)
                .padding(.leading, 2)
                .opacity(isSelected ? 1 : 0)
        }
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            radius: 4,
            x: 0,
            y: 2
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
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
    @ObservedObject var session: SurveyPageSession
    @ObservedObject var store: RuleStore
    @ObservedObject private var webController: SurveyWebController
    let isSelected: Bool
    let hasNextPage: Bool
    let onSynchronizeSurveyURL: (String) -> Void
    let onNextPage: () -> Void
    let onSubmissionCompleted: () -> Void
    @State private var showingRules = false
    @State private var showingLogs = false

    init(
        session: SurveyPageSession,
        store: RuleStore,
        isSelected: Bool,
        hasNextPage: Bool,
        onSynchronizeSurveyURL: @escaping (String) -> Void,
        onNextPage: @escaping () -> Void,
        onSubmissionCompleted: @escaping () -> Void
    ) {
        _session = ObservedObject(wrappedValue: session)
        _store = ObservedObject(wrappedValue: store)
        _webController = ObservedObject(wrappedValue: session.controller)
        self.isSelected = isSelected
        self.hasNextPage = hasNextPage
        self.onSynchronizeSurveyURL = onSynchronizeSurveyURL
        self.onNextPage = onNextPage
        self.onSubmissionCompleted = onSubmissionCompleted
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
                            submitDelaySeconds: session.submitDelaySeconds,
                            isSelected: isSelected,
                            initialLoadDelaySeconds: isSelected
                                ? 0
                                : min(Double(max(session.pageNumber - 1, 0)) * 0.06, 0.6)
                        )
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
                    submitDelaySeconds: submitDelaySecondsBinding,
                    isPresetSelectionLocked: true
                )
                    .onDisappear {
                        onSynchronizeSurveyURL(session.surveyURLString)
                    }
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingLogs) {
                AutomationLogView(controller: webController)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert(item: visibleNoticeBinding) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
            .onChange(of: webController.state) { state in
                guard isSelected, case .submitted = state else { return }
                onSubmissionCompleted()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                nextPageBar
            }
        }
    }

    private var nextPageBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: onNextPage) {
                HStack(spacing: 8) {
                    Text("下一页")
                    Image(systemName: "chevron.right")
                }
                .font(.headline)
                .frame(maxWidth: 280)
                .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasNextPage)
            .help(hasNextPage ? "打开下一页" : "已经是最后一页")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
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
                guard let url = session.surveyURL else { return }
                webController.reopenSurvey(url)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(session.surveyURL == nil || webController.isBusy)
            .help("按保存地址重新打开")

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

    private var selectedPreset: SubmissionPreset? {
        store.presets.first { $0.id == session.selectedPresetID } ?? store.presets.first
    }

    private var selectedPresetIDBinding: Binding<UUID> {
        Binding(
            get: { session.selectedPresetID },
            set: { _ in }
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
