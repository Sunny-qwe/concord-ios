// ThemeLivePreview.swift — live theme preview (FlClash:
// lib/views/theme_preview.dart ThemeLivePreview + MiniScreen).
//
// v0.2.141 (C2-c3): replaces the old static preview card (BlobIcon
// + "运行中" pill + progress bar + mode pills) with upstream's full
// live MiniScreen: a 168pt phone frame (aspect 9:17) sketching the
// app's four pages under the LIVE theme — accent, appearance,
// floating vs docked bar, liquid glass — with a tappable tab bar.
// Tapping a tab switches the sketched page with the user's chosen
// tab animation (slide offsets, fade cross-fades, ~300 ms), and
// changing the animation setting advances the preview one tab, as
// upstream's listener does. The sketches are shape-based (the
// upstream CustomPainter translated 1:1 in the same unit grid:
// unit = width/20, margin = unit*1.5, floating bar = unit*3.2,
// docked bar = unit*3.6).

import SwiftUI

/// The live theme preview at the top of the Theme page.
struct ThemeLivePreview: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var selected = 0
    @State private var previous = 0

    /// Phone width, upstream _phoneWidth = 168.
    private static let phoneWidth: CGFloat = 168
    private static let phoneHeight: CGFloat = 168 * 17 / 9

    private var unit: CGFloat { Self.phoneWidth / 20 }
    private var floatingBar: Bool { themeStore.navBarStyle == .floating }
    private var glass: Bool { floatingBar && themeStore.liquidGlass != .none }
    private var barHeight: CGFloat { floatingBar ? unit * 3.2 : unit * 3.6 }

    var body: some View {
        VStack {
            ZStack(alignment: .topLeading) {
                // Page background, live with the theme.
                ConcordTheme.pageBackground
                // The sketched page (clipped to the content rect:
                // under the floating bar, above the docked bar).
                // The id swaps the sketch per tab so the transition
                // animates the page change (slide offsets, fade
                // cross-fades, upstream _select).
                MiniPageSketch(page: selected, unit: unit, floatingBar: floatingBar)
                    .frame(width: Self.phoneWidth - unit * 3,
                           height: Self.phoneHeight - unit * 1.5 - (floatingBar ? 0 : barHeight))
                    .position(x: Self.phoneWidth / 2,
                              y: (Self.phoneHeight - unit * 1.5 - (floatingBar ? 0 : barHeight)) / 2 + unit * 1.5)
                    .clipped()
                    .id(selected)
                    .transition(pageTransition)
                    .animation(.easeOut(duration: 0.3), value: selected)
                // The tab bar.
                miniTabBar
            }
            .frame(width: Self.phoneWidth, height: Self.phoneHeight)
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .onChange(of: themeStore.tabAnimation) { _, _ in
            // Upstream: changing the tab animation advances the
            // preview one tab, so the new animation is visible.
            select((selected + 1) % MiniPageSketch.pageCount)
        }
    }

    private func select(_ index: Int) {
        guard index != selected else { return }
        previous = selected
        selected = index
    }

    /// The page-change transition: fade cross-fades; slide offsets
    /// the pages in the direction of travel (upstream _paintPages).
    private var pageTransition: AnyTransition {
        if themeStore.tabAnimation == .fade { return .opacity }
        let forward = selected >= previous
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing))
    }

    /// The tab bar: a floating capsule with shadow (glass when
    /// liquid glass is on), or a docked full-width rect; the
    /// selected destination gets the indicator pill, a primary dot
    /// and a primary label bar (upstream _paintDestinations).
    private var miniTabBar: some View {
        let margin = unit * 1.5
        let barRect: CGRect = floatingBar
            ? CGRect(x: margin, y: Self.phoneHeight - margin - barHeight,
                     width: Self.phoneWidth - margin * 2, height: barHeight)
            : CGRect(x: 0, y: Self.phoneHeight - barHeight,
                     width: Self.phoneWidth, height: barHeight)
        return ZStack(alignment: .topLeading) {
            if glass {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.5),
                                             Color.white.opacity(0.08),
                                             Color.white.opacity(0.3)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: unit * 0.15)
                    )
                    .shadow(color: Color(.label).opacity(0.12),
                            radius: unit, x: 0, y: unit * 0.3)
            } else if floatingBar {
                Capsule()
                    .fill(ConcordTheme.cardBackground)
                    .shadow(color: Color(.label).opacity(0.12),
                            radius: unit, x: 0, y: unit * 0.3)
            } else {
                Rectangle()
                    .fill(ConcordTheme.cardBackground)
            }
            HStack(spacing: 0) {
                ForEach(0..<MiniPageSketch.pageCount, id: \.self) { i in
                    miniDestination(i, cellWidth: barRect.width / CGFloat(MiniPageSketch.pageCount))
                }
            }
        }
        .frame(width: barRect.width, height: barRect.height)
        .position(x: barRect.midX, y: barRect.midY)
    }

    private func miniDestination(_ index: Int, cellWidth: CGFloat) -> some View {
        let isSelected = index == selected
        let ink: Color = isSelected ? themeStore.accentColor : Color(.label).opacity(0.55)
        return ZStack {
            if isSelected {
                Capsule()
                    .fill(ConcordTheme.softFill)
                    .frame(width: floatingBar ? cellWidth - unit * 0.5 : unit * 2.8,
                           height: floatingBar ? barHeight - unit * 0.5 : unit * 1.5)
                    .position(x: cellWidth / 2,
                              y: floatingBar ? barHeight / 2 : barHeight / 2 - unit * 0.4)
            }
            // Icon dot.
            Circle()
                .fill(ink)
                .frame(width: unit * 0.9, height: unit * 0.9)
                .position(x: cellWidth / 2, y: barHeight / 2 - unit * 0.4)
            // Label bar.
            Capsule()
                .fill(isSelected ? ink : ink.opacity(0.6))
                .frame(width: unit * 1.7, height: unit * 0.35)
                .position(x: cellWidth / 2, y: barHeight / 2 + unit * 0.8)
        }
        .frame(width: cellWidth, height: barHeight)
        .contentShape(Rectangle())
        .onTapGesture { select(index) }
    }
}

// MARK: - One sketched page (upstream _PageSketch)

/// A sketched page in upstream's unit grid (unit = phone width/20;
/// the sketch is 17 units wide: content width = width - 2*margin).
/// All coordinates are upstream's, in units from the content's top
/// left; the view is clipped to the content rect by its parent.
private struct MiniPageSketch: View {
    static let pageCount = 4

    let page: Int
    let unit: CGFloat
    let floatingBar: Bool

    /// Content width in units (upstream _PageSketch.width).
    private var width: CGFloat { 17 }

    private var card: Color { ConcordTheme.cardBackground }
    private var inset: Color { ConcordTheme.softFill }
    private var text: Color { Color(.label).opacity(0.72) }
    private var line: Color { Color(.label).opacity(0.4) }
    private var faint: Color { Color(.label).opacity(0.16) }
    @EnvironmentObject private var themeStore: ThemeStore
    private var primary: Color { themeStore.accentColor }
    private var onPrimary: Color { .white }

    var body: some View {
        // No fixed frame here: the parent sizes this sketch to the
        // content rect, and every child is absolutely positioned
        // from the top left (a ZStack of positioned children has
        // no intrinsic size). A fixed tall frame would centre the
        // sketch in the parent and shift every row down.
        ZStack(alignment: .topLeading) {
            switch page % Self.pageCount {
            case 0: dashboard
            case 1: proxies
            case 2: profiles
            default: tools
            }
        }
    }

    // MARK: - Shape helpers (upstream _rect / _block / _pill / _dot)

    private func block(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                       color: Color, extent: CGFloat = 5) -> some View {
        RoundedRectangle(cornerRadius: min(extent * unit, h * unit / 2))
            .fill(color)
            .frame(width: w * unit, height: h * unit)
            .position(x: (x + w / 2) * unit, y: (y + h / 2) * unit)
    }

    private func pill(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: w * unit, height: h * unit)
            .position(x: (x + w / 2) * unit, y: (y + h / 2) * unit)
    }

    private func dot(x: CGFloat, y: CGFloat, radius: CGFloat, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: radius * 2 * unit, height: radius * 2 * unit)
            .position(x: x * unit, y: y * unit)
    }

    /// The title pill and the round action buttons; returns where
    /// the body starts (upstream _header, top = 2.8).
    private func header(actions: Int) -> some View {
        ZStack(alignment: .topLeading) {
            pill(x: 0, y: 0.45, w: 7, h: 1.1, color: text)
            ForEach(0..<actions, id: \.self) { i in
                let x = width - 1 - CGFloat(i) * 2.4
                dot(x: x, y: 1, radius: 1, color: card)
                dot(x: x, y: 1, radius: 0.3, color: line)
            }
        }
    }

    // MARK: - Dashboard (upstream _dashboard)

    private var dashboard: some View {
        ZStack(alignment: .topLeading) {
            header(actions: 1)
            // Status card.
            let y0: CGFloat = 2.8
            block(x: 0, y: y0, w: width, h: 6.2, color: card)
            // The big primary-tinted circle behind the play button,
            // clipped to the status card (upstream clips it to the
            // card path; without the clip it spills onto the page).
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(primary.opacity(0.1))
                    .frame(width: unit * 9.2, height: unit * 9.2)
                    .position(x: (width - 3) * unit, y: 3.1 * unit)
            }
            .frame(width: width * unit, height: 6.2 * unit)
            .position(x: width * unit / 2, y: (y0 + 3.1) * unit)
            .clipShape(RoundedRectangle(cornerRadius: min(5 * unit, 6.2 * unit / 2)))
            dot(x: width - 3, y: y0 + 3.1, radius: 1.8, color: primary)
            pill(x: width - 3 - 0.675, y: y0 + 3.1 - 0.6, w: 0.35, h: 1.2, color: onPrimary)
            pill(x: width - 3 + 0.325, y: y0 + 3.1 - 0.6, w: 0.35, h: 1.2, color: onPrimary)
            pill(x: 1, y: y0 + 0.9, w: 3, h: 0.7, color: line)
            dot(x: 1.9, y: y0 + 3, radius: 0.9, color: inset)
            pill(x: 3.5, y: y0 + 2.3, w: 5, h: 0.9, color: text)
            pill(x: 3.5, y: y0 + 3.5, w: 2.4, h: 0.7, color: inset)
            pill(x: 1, y: y0 + 4.8, w: 2.4, h: 0.7, color: line)
            pill(x: 4.6, y: y0 + 4.8, w: 3.6, h: 0.7, color: line)
            // Traffic card with the two speed tiles.
            let y1: CGFloat = y0 + 6.2 + 0.6
            block(x: 0, y: y1, w: width, h: 5.8, color: card)
            pill(x: 1, y: y1 + 0.9, w: 4.5, h: 0.7, color: line)
            let tileWidth = (width - 2.6) / 2
            ForEach(0..<2, id: \.self) { i in
                let x = 1 + CGFloat(i) * (tileWidth + 0.6)
                let tile = CGRect(x: x * unit, y: (y1 + 2.1) * unit,
                                  width: tileWidth * unit, height: 2.9 * unit)
                RoundedRectangle(cornerRadius: min(2.9 * unit, tile.height / 2))
                    .fill(inset)
                    .frame(width: tile.width, height: tile.height)
                    .position(x: tile.midX, y: tile.midY)
                pill(x: x + 0.6, y: y1 + 2.65, w: 2.4, h: 0.7, color: line)
                // Area first, then the stroke (upstream draws the
                // fill before the line).
                MiniSpeedGraphArea(phase: CGFloat(i) * 1.7, unit: unit)
                    .fill((i == 0 ? primary.opacity(0.5) : primary).opacity(0.2))
                    .frame(width: tile.width, height: tile.height)
                    .position(x: tile.midX, y: tile.midY)
                    .clipShape(RoundedRectangle(cornerRadius: min(2.9 * unit, tile.height / 2)))
                MiniSpeedGraph(phase: CGFloat(i) * 1.7, unit: unit)
                    .stroke(i == 0 ? primary.opacity(0.5) : primary,
                            lineWidth: unit * 0.15)
                    .frame(width: tile.width, height: tile.height)
                    .position(x: tile.midX, y: tile.midY)
                    .clipShape(RoundedRectangle(cornerRadius: min(2.9 * unit, tile.height / 2)))
            }
            // Mode segment card.
            let y2: CGFloat = y1 + 5.8 + 0.6
            block(x: 0, y: y2, w: width, h: 4.4, color: card)
            pill(x: 1, y: y2 + 0.9, w: 4, h: 0.7, color: line)
            let segment = (width - 2.6) / 3
            ForEach(0..<3, id: \.self) { i in
                let x = 1 + CGFloat(i) * (segment + 0.3)
                pill(x: x, y: y2 + 2.1, w: segment, h: 1.6,
                     color: i == 0 ? primary : inset)
                dot(x: x + segment / 2, y: y2 + 2.9, radius: 0.3,
                    color: i == 0 ? onPrimary : line)
            }
            // Row card.
            let y3: CGFloat = y2 + 4.4 + 0.6
            block(x: 0, y: y3, w: width, h: 3, color: card)
            dot(x: 1.9, y: y3 + 1.5, radius: 0.9, color: primary)
            pill(x: 3.4, y: y3 + 1.1, w: 2.4, h: 0.8, color: line)
            pill(x: width - 3.6, y: y3 + 0.8, w: 2.6, h: 1.4, color: primary)
            dot(x: width - 1.7, y: y3 + 1.5, radius: 0.55, color: onPrimary)
            // Three list cards.
            let y4: CGFloat = y3 + 3 + 0.6
            ForEach(0..<3, id: \.self) { i in
                let y = y4 + CGFloat(i) * (4.5 + 0.6)
                block(x: 0, y: y, w: width, h: 4.5, color: card)
                pill(x: 1, y: y + 0.9, w: 3.5 + CGFloat(i % 2), h: 0.7, color: line)
            }
        }
    }

    // MARK: - Proxies (upstream _proxies: 9 rows)

    private var proxies: some View {
        ZStack(alignment: .topLeading) {
            header(actions: 2)
            ForEach(0..<9, id: \.self) { i in
                let y: CGFloat = 2.8 + CGFloat(i) * (2.6 + 0.6)
                block(x: 0, y: y, w: width, h: 2.6, color: card)
                dot(x: 1.5, y: y + 1.3, radius: 0.8, color: inset)
                pill(x: 3, y: y + 0.6, w: 3 + CGFloat(i % 3), h: 0.7, color: line)
                pill(x: 3, y: y + 1.55, w: 4, h: 0.5, color: faint)
                pill(x: width - 4.4, y: y + 1.05, w: 1.8, h: 0.5, color: faint)
                dot(x: width - 1.3, y: y + 1.3, radius: 0.55, color: inset)
            }
        }
    }

    // MARK: - Profiles (upstream _profiles: 3 cards)

    private var profiles: some View {
        ZStack(alignment: .topLeading) {
            header(actions: 2)
            ForEach(0..<3, id: \.self) { i in
                let y: CGFloat = 2.8 + CGFloat(i) * (2.8 + 0.6)
                block(x: 0, y: y, w: width, h: 2.8, color: card)
                pill(x: 1, y: y + 0.7, w: 3.4 - CGFloat(i) * 0.6, h: 0.75, color: line)
                pill(x: 4.8 - CGFloat(i) * 0.6, y: y + 0.72, w: 2.6, h: 0.7,
                     color: primary.opacity(0.16))
                pill(x: 1, y: y + 1.7, w: 3, h: 0.5, color: faint)
                pill(x: width - 4.1, y: y + 1.15, w: 1.6, h: 0.5, color: faint)
                if i == 0 {
                    dot(x: width - 1.4, y: y + 1.4, radius: 0.6, color: primary)
                }
            }
        }
    }

    // MARK: - Tools (upstream _tools: sections of 4 and 7 rows)

    private var tools: some View {
        ZStack(alignment: .topLeading) {
            header(actions: 0)
            let sections = [4, 7]
            // y positions are cumulative; computed inline per section.
            toolsSection(rows: sections[0], top: 2.8)
            toolsSection(rows: sections[1], top: 2.8 + 1.3 + CGFloat(sections[0]) * 2.4 + 1.2)
        }
    }

    private func toolsSection(rows: Int, top: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            pill(x: 0.8, y: top + 0.2, w: 1.6 + CGFloat(rows) * 0.15, h: 0.5, color: faint)
            let y = top + 1.3
            block(x: 0, y: y, w: width, h: CGFloat(rows) * 2.4, color: card)
            ForEach(0..<rows, id: \.self) { i in
                let row = y + CGFloat(i) * 2.4
                dot(x: 1.3, y: row + 1.2, radius: 0.45, color: line)
                pill(x: 2.6, y: row + 0.85, w: 4 + CGFloat((i * 3 + rows) % 4), h: 0.7, color: line)
                if i < rows - 1 {
                    Rectangle()
                        .fill(faint)
                        .frame(width: (width - 3.4) * unit, height: 0.06 * unit)
                        .position(x: (2.6 + (width - 3.4) / 2) * unit, y: (row + 2.4 - 0.03) * unit)
                }
            }
        }
    }
}

// MARK: - Speed graph (upstream _speedGraph: 16-step sine)

/// The sine stroke of a traffic tile.
private struct MiniSpeedGraph: Shape {
    var phase: CGFloat
    var unit: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 16
        for i in 0...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let y = rect.minY + rect.height * 0.68
                + sin(CGFloat(i) * 0.9 + phase) * unit * 0.35
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// The filled area under the sine stroke.
private struct MiniSpeedGraphArea: Shape {
    var phase: CGFloat
    var unit: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = MiniSpeedGraph(phase: phase, unit: unit).path(in: rect)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
