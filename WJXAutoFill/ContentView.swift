import SwiftUI

struct ContentView: View {
    private enum ConfirmationAction {
        case singleSubmit
        case testQueue
    }

    @StateObject private var store = RuleStore()
    @StateObject private var webController = SurveyWebController()
    @State private var showingRules = false
    @State private var showingConfirmation = false
    @State private var confirmationAction: ConfirmationAction = .singleSubmit

    var body: some View {
        NavigationStack {
            Group {
                if let url = store.surveyURL {
                    VStack(spacing: 0) {
                        statusBar
                        SurveyWebView(
                            controller: webController,
                            url: url,
                            rules: store.selectedPreset?.rules ?? [],
                            autoFillOnLoad: store.autoFillOnLoad
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        webController.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.surveyURL == nil || webController.isQueueRunning)

                    Button {
                        showingRules = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .disabled(webController.isQueueRunning)
                }
            }
            .sheet(isPresented: $showingRules) {
                RuleEditorView(store: store, detectedQuestions: webController.detectedQuestions)
            }
            .confirmationDialog("确认操作", isPresented: $showingConfirmation, titleVisibility: .visible) {
                switch confirmationAction {
                case .singleSubmit:
                    Button("确认单次提交", role: .destructive) {
                        webController.submitOnce()
                    }
                case .testQueue:
                    Button("开始 \(store.queuePresets.count) 个预设的测试", role: .destructive) {
                        guard let url = store.surveyURL else { return }
                        webController.startTestQueue(
                            presets: store.queuePresets,
                            surveyURL: url,
                            delay: store.queueDelaySeconds
                        )
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                switch confirmationAction {
                case .singleSubmit:
                    Text("请先核对页面中的所有答案。此操作只触发一次提交。")
                case .testQueue:
                    Text("应用会按预设顺序自动填写和提交，每次成功后等待 \(Int(store.queueDelaySeconds)) 秒再继续。请仅用于你获授权的测试问卷。")
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
                        webController.fill(rules: store.selectedPreset?.rules ?? [])
                    } label: {
                        Label("自动填写", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

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
                    Label("按顺序连续测试 \(store.queuePresets.count) 个预设", systemImage: "person.2.fill")
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
            return "连续测试 \(current)/\(total)：\(presetName)"
        case .completed(let total):
            return "连续测试完成：已提交 \(total) 个预设"
        case .stopped(let message):
            return "连续测试已停止：\(message)"
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
        guard store.queuePresets.count >= 2, store.surveyURL != nil else { return false }
        switch webController.state {
        case .ready(_), .submitted(_):
            return true
        default:
            return false
        }
    }

    private var queueProgressText: String {
        if case .running(let current, let total, let presetName) = webController.queueState {
            return "\(current)/\(total) · \(presetName)"
        }
        return "连续测试运行中"
    }
}

#Preview {
    ContentView()
}
