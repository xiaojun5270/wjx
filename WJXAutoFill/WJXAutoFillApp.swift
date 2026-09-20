import SwiftUI

@main
struct WJXAutoFillApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 全局设计令牌（iOS 26 Liquid Glass）
//
// 统一配色、圆角、间距与状态语义色，供各界面复用。
// 玻璃材质只用于「浮层」——工具栏、侧栏浮标、状态浮条、悬浮按钮，
// 不放进可滚动的列表行里（避免逐行采样、玻璃套玻璃）。
//
// 说明：这些设计系统代码原本放在独立的 DesignSystem.swift，
// 为避免「新建文件漏推 / 未登记进构建」导致 CI 找不到输入文件，
// 现合并进本文件（本文件一直在版本控制与构建中）。

enum AppTheme {
    /// 品牌主色：靛紫，作为全局 accent / tint 使用。
    static let brand = Color(red: 0.36, green: 0.31, blue: 0.87)
    /// 次级点缀色，用于渐变与高亮。
    static let brandSoft = Color(red: 0.53, green: 0.45, blue: 0.96)

    static let cardRadius: CGFloat = 22
    static let innerRadius: CGFloat = 16
    static let chipRadius: CGFloat = 14

    static let railWidthRegular: CGFloat = 214

    /// 侧栏 / 分组背景。
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

    /// 品牌渐变，用于图标徽章、进度等强调场景。
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brandSoft, brand],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 状态语义色

enum StatusTone {
    case idle
    case running
    case waiting
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .idle: return Color.secondary
        case .running: return AppTheme.brand
        case .waiting: return .orange
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

// MARK: - 复用组件

/// 圆形图标徽章：状态色描边 + 柔和底色，玻璃浮条内的强调图标。
struct GlassIconBadge: View {
    let systemName: String
    var tone: StatusTone = .running
    var size: CGFloat = 34
    var useBrandGradient: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tone.color.opacity(0.16))
            Circle()
                .strokeBorder(tone.color.opacity(0.30), lineWidth: 1)
            if useBrandGradient {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(AppTheme.brandGradient)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tone.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 胶囊数字/文字标签，浮层内的计数标记。
struct CountChip: View {
    let text: String
    var tone: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(tone.opacity(0.14))
            )
    }
}

// MARK: - View 修饰

extension View {
    /// 滚动内容里的卡片：不用玻璃，改用分组底色 + 细描边 + 连续圆角。
    func softCard(
        radius: CGFloat = AppTheme.innerRadius,
        tint: Color? = nil,
        fill: Color = AppTheme.cardBackground
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        (tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.24),
                        lineWidth: 1
                    )
            )
    }

    /// 浮层玻璃背景（工具条、状态浮条、浮标等）。
    func floatingGlass(radius: CGFloat = AppTheme.cardRadius) -> some View {
        self.glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}
