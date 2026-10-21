import SwiftUI
import AppKit
import StratagemCore

struct OverlayView: View {
    @ObservedObject var overlay: OverlayManager
    @ObservedObject var executor: WorkflowExecutor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ink = Color(red: 0.94, green: 0.94, blue: 0.87)
    private let glass = Color(red: 0.075, green: 0.085, blue: 0.075).opacity(0.96)
    private var rowCount: Int { overlay.matched == nil ? max(1, overlay.candidates.count) : 1 }
    private var listHeight: CGFloat {
        if let pending = overlay.pending {
            let text = overlay.model.previewText(pending, config: overlay.model.committed) as NSString
            let bounds = text.boundingRect(with: NSSize(width: max(40, overlay.panelSize.width - 62), height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                           attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            return min(ceil(bounds.height) + 94, overlay.panelSize.height - 58)
        }
        return min(CGFloat(min(rowCount, 7)) * 52 + 16, overlay.panelSize.height - 58)
    }
    private var feedback: String? {
        if overlay.executionRejected { return overlay.status }
        if overlay.status.hasPrefix("序列错误") { return "INPUT ERROR" }
        if overlay.status.hasPrefix("输入超时") { return "TIMED OUT" }
        if overlay.status.contains("序列冲突") { return "SEQUENCE CONFLICT" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "scope").font(.system(size: 16, weight: .medium))
                Text("STRATAGEMS").font(.custom("DINAlternate-Bold", size: 16))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 30)
            .background(glass)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.36)).frame(height: 0.5) }
            .overlay(alignment: .leading) {
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(ink.opacity(0.6)).offset(x: -18)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let entry = overlay.matched {
                        GameHUDRow(entry: entry, progress: overlay.input.count, state: executionLabel)
                        if let pending = overlay.pending {
                            Text(overlay.model.previewText(pending, config: overlay.model.committed))
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(ink).padding(.top, 10).padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(overlay.candidates) { entry in
                            GameHUDRow(entry: entry, progress: overlay.input.count)
                        }
                        if overlay.candidates.isEmpty {
                            Text("NO STRATAGEMS").font(.custom("DINAlternate-Bold", size: 14)).padding(10)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(8)
            .frame(height: listHeight)
            .background(glass)
            .overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 0.5))
            .overlay(alignment: .leading) {
                HUDSideBracket().stroke(ink.opacity(0.22), lineWidth: 0.6).frame(width: 7).offset(x: -26)
            }
            if let feedback {
                Text(feedback).font(.custom("DINAlternate-Bold", size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.70, blue: 0.48))
                    .padding(.horizontal, 8).padding(.vertical, 5).background(glass)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(.leading, 28).padding(.trailing, 10).padding(.top, 8)
        .frame(width: overlay.panelSize.width, height: overlay.panelSize.height, alignment: .topLeading)
        .offset(x: overlay.presented ? 0 : -6)
        .opacity(overlay.presented ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: overlay.presented)
        .environment(\.colorScheme, .dark)
    }
    private var executionLabel: String {
        if overlay.pending != nil { return "CONFIRM  ↵" }
        if overlay.executionRejected { return "BLOCKED" }
        switch executor.status {
        case .running: return "ACTIVATING"
        case .succeeded: return "COMPLETE"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }
}

private struct GameHUDRow: View {
    let entry: Stratagem
    let progress: Int
    var state: String? = nil
    private let ink = Color(red: 0.94, green: 0.94, blue: 0.87)
    private var accent: Color {
        if let color = GameArtwork.shared.accent(for: entry) { return Color(nsColor: color) }
        let n = entry.name.lowercased()
        if n.contains("sentry") || n.contains("emplacement") || n.contains("relay") || n.contains("tower") {
            return Color(red: 0.55, green: 0.79, blue: 0.52)
        }
        if entry.category == "Orbital" || entry.category == "Eagle" {
            return Color(red: 0.88, green: 0.40, blue: 0.35)
        }
        if entry.category == "Equipment" { return Color(red: 0.50, green: 0.77, blue: 0.83) }
        return Color(red: 0.79, green: 0.70, blue: 0.41)
    }
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = GameArtwork.shared.image(for: entry) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.icon.hasPrefix("/") ? "command.square" : entry.icon)
                        .resizable().scaledToFit().padding(7).foregroundStyle(ink)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.10))
            .overlay(Rectangle().stroke(accent, lineWidth: 2))
            VStack(alignment: .leading, spacing: 5) {
                Text(GameArtwork.shared.displayName(for: entry).uppercased())
                    .font(.custom("DINAlternate-Bold", size: 15))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(ink.opacity(0.92))
                if let state {
                    Text(state).font(.custom("DINAlternate-Bold", size: 14))
                        .foregroundStyle(state == "FAILED" ? Color(red: 1, green: 0.55, blue: 0.45) : ink)
                        .frame(height: 17)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(entry.sequence.enumerated()), id: \.offset) { index, direction in
                            HUDArrow().fill(index < progress ? Color(red: 1, green: 0.88, blue: 0.32) : ink)
                                .rotationEffect(.degrees(rotation(direction)))
                                .frame(width: 16, height: 16)
                        }
                    }.frame(height: 17)
                        .accessibilityLabel(entry.sequenceText)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 52)
        .accessibilityElement(children: .combine)
    }
    private func rotation(_ direction: Direction) -> Double {
        switch direction { case .up: return 0; case .right: return 90; case .down: return 180; case .left: return 270 }
    }
}

/// Block arrows match the game HUD's proportions without relying on font glyphs.
private struct HUDArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.5,0.04),(0.98,0.53),(0.73,0.53),(0.73,0.96),(0.27,0.96),(0.27,0.53),(0.02,0.53)]
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = CGPoint(x: rect.minX + point.0 * rect.width, y: rect.minY + point.1 * rect.height)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }
}
private struct HUDSideBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
