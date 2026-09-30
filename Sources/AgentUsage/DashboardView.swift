import AgentUsageCore
import SwiftUI

struct DashboardView: View {
    var showsDismiss: Bool
    /// Caps the card scroll view. Nil in a normal window, so the list uses the window height.
    var scrollLimit: CGFloat? = nil
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enabledProviders") private var enabledRaw = ProviderID.all.joined(separator: ",")
    @AppStorage("providerOrder") private var orderRaw = ProviderID.all.joined(separator: ",")

    var body: some View {
        let limit: CGFloat? = scrollLimit ?? (showsDismiss ? 680 : nil)
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            DashboardBody(
                showsDismiss: showsDismiss,
                now: timeline.date,
                snapshots: visibleSnapshots,
                refreshing: stillLoading,
                scrollLimit: limit,
                dismiss: { dismiss() },
                refresh: { store.refresh(force: true) },
                move: moveVisible
            )
        }
        .modifier(PanelFrame(fillsWindow: limit == nil))
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onAppear { store.refresh(force: true) }
        .onChange(of: enabledRaw) { _, _ in store.refresh(force: true) }
        .onKeyPress(phases: .down) { press in
            guard press.characters.lowercased() == "r" else { return .ignored }
            store.refresh(force: true)
            return .handled
        }
    }

    private var enabled: [String] {
        ProviderList.enabled(order: ProviderList.normalizedOrder(orderRaw), enabledRaw: enabledRaw)
    }

    private func moveVisible(source: String, before target: String) {
        var visible = enabled
        guard source != target, let from = visible.firstIndex(of: source) else { return }
        visible.remove(at: from)
        let destination = visible.firstIndex(of: target) ?? visible.endIndex
        visible.insert(source, at: destination)
        orderRaw = ProviderList.applyVisible(visible, to: ProviderList.normalizedOrder(orderRaw)).joined(separator: ",")
    }

    /// The header stays on "R to refresh" once any card has real data. A keychain prompt can outlast the other providers.
    private var stillLoading: Bool {
        store.refreshing && visibleSnapshots.allSatisfy { snapshot in
            if case .failed(let message) = snapshot.status {
                return message == "Refreshing…" || message == "Waiting to refresh"
            }
            return false
        }
    }

    private var visibleSnapshots: [ProviderSnapshot] {
        enabled.map { id in
            store.snapshots.first { $0.id == id } ?? ProviderSnapshot(
                id: id,
                name: ProviderID.name(id),
                symbol: ProviderID.symbol(id),
                status: .failed(store.refreshing ? "Refreshing…" : "Waiting to refresh")
            )
        }
    }
}

private struct DashboardBody: View {
    var showsDismiss: Bool
    var now: Date
    var snapshots: [ProviderSnapshot]
    var refreshing: Bool
    var scrollLimit: CGFloat?
    var dismiss: () -> Void
    var refresh: () -> Void
    var move: (String, String) -> Void
    @State private var selectedID: String?

    var body: some View {
        let stack = VStack(spacing: 0) {
            chipBar
            card
        }
        if scrollLimit == nil {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            stack.frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var chipBar: some View {
        HStack(spacing: 8) {
            if showsDismiss {
                Button(action: dismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Close")
            }
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: 16) {
                            ForEach(snapshots) { snapshot in
                                chip(snapshot)
                                    .id("chip-\(snapshot.id)")
                            }
                        }
                        .padding(.vertical, 8)
                        .onChange(of: selectedID) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo("chip-\(id)", anchor: .center) }
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(height: 40)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .foregroundStyle(Theme.primary)
    }

    private func chip(_ snapshot: ProviderSnapshot) -> some View {
        let active = (selectedID ?? snapshots.first?.id) == snapshot.id
        return Button {
            selectedID = snapshot.id
        } label: {
            VStack(spacing: 6) {
                Text(chipTitle(snapshot))
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                Rectangle()
                    .fill(active ? Theme.border : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .help("Drag to reorder")
        .draggable(snapshot.id)
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first else { return false }
            move(source, snapshot.id)
            return true
        }
    }

    private func chipTitle(_ snapshot: ProviderSnapshot) -> String {
        guard snapshot.status == .ready, let headline = snapshot.headline else { return snapshot.name }
        if let used = headline.usedPercent {
            var text = "\(snapshot.name) \(Format.percent(used))"
            if let resetsAt = headline.resetsAt {
                text += " · \(Format.remaining(resetsAt.timeIntervalSince(now)))"
            }
            return text
        }
        if let amount = headline.amountText {
            return "\(snapshot.name) \(amount)"
        }
        return snapshot.name
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("AGENT USAGE")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.8)
                Spacer()
                Button(action: refresh) {
                    Text(refreshing ? "Refreshing…" : "R to refresh")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .keyboardShortcut("r", modifiers: [])
            }
            .foregroundStyle(Theme.primary)
            .padding(.bottom, 10)
            Divider().overlay(Theme.hairline)

            if snapshots.isEmpty {
                Text("Turn on a provider in Settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 28)
            } else if let scrollLimit {
                cardScroll(maxHeight: scrollLimit)
            } else {
                GeometryReader { geo in
                    cardScroll(maxHeight: geo.size.height)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: scrollLimit == nil ? .infinity : nil, alignment: .top)
        .background(Theme.background)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 1.5))
        .padding(12)
    }

    private func cardScroll(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        ProviderCard(snapshot: snapshot, now: now)
                            .id(snapshot.id)
                            .padding(.vertical, 16)
                        if index < snapshots.count - 1 {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

/// The menu-bar panel keeps the designed width. A normal window follows the frame the user sets.
private struct PanelFrame: ViewModifier {
    var fillsWindow: Bool

    func body(content: Content) -> some View {
        if fillsWindow {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(width: 580)
        }
    }
}

private struct ProviderCard: View {
    var snapshot: ProviderSnapshot
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(snapshot.id == ProviderID.claude ? Theme.claude : Theme.secondary)
                Text(snapshot.name)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.primary)
            }
            switch snapshot.status {
            case .ready:
                readyBody
            case .signedOut(let message), .failed(let message):
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var readyBody: some View {
        if let headline = snapshot.headline {
            Text(Format.usedLine(headline, now: now, includeResetsWord: true))
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            UsageBar(percent: headline.usedPercent)
            if let pace = pace(for: headline) {
                HStack {
                    Text(pace.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 8)
                    Text(pace.expectedLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            }
        }
        if snapshot.stale, let fetchedAt = snapshot.fetchedAt {
            Text("updated \(Format.remaining(now.timeIntervalSince(fetchedAt))) ago")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        if !snapshot.days.isEmpty {
            WeekBars(days: snapshot.days, unit: snapshot.chartUnit)
        }
        if let note = snapshot.chartNote {
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !snapshot.extras.isEmpty {
            VStack(spacing: 8) {
                ForEach(snapshot.extras) { extra in
                    HStack(alignment: .firstTextBaseline) {
                        Text(extra.label)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(extraLine(extra))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 14))
                }
            }
            .padding(.top, 4)
        }
    }

    private func pace(for window: QuotaWindow) -> Pace? {
        guard let used = window.usedPercent, let resetsAt = window.resetsAt, let length = window.window else { return nil }
        return PaceMath.make(usedPercent: used, resetsAt: resetsAt, window: length, now: now)
    }

    private func extraLine(_ window: QuotaWindow) -> String {
        let line = Format.usedLine(window, now: now, includeResetsWord: false)
        if let detail = window.detail, !line.isEmpty, detail != line {
            return "\(line) · \(detail)"
        }
        if line.isEmpty, let detail = window.detail { return detail }
        return line
    }
}

private struct UsageBar: View {
    var percent: Double?

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, (percent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.fill).frame(width: max(6, geometry.size.width * fraction))
            }
        }
        .frame(height: 7)
        .padding(.vertical, 2)
    }
}

private struct WeekBars: View {
    var days: [DayBar]
    var unit: ChartUnit

    var body: some View {
        let total = days.compactMap(\.amount).reduce(0, +)
        let peak = days.compactMap(\.amount).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text("LAST 7 DAYS · \(Format.chartAmount(total, unit: unit)) \(unit == .tokens ? "TOKENS" : "CREDITS")")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        Text(day.amount.map { Format.chartAmount($0, unit: unit) } ?? " ")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        bar(day.amount, peak: peak)
                        Text(Format.weekday(day.date))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
        }
        .padding(.top, 6)
    }

    private func bar(_ amount: Double?, peak: Double) -> some View {
        let height: CGFloat
        if let amount {
            if amount <= 0 || peak <= 0 {
                height = 3
            } else {
                height = max(8, 46 * amount / peak)
            }
        } else {
            height = 0
        }
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(amount == nil ? Color.clear : Theme.bar)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, 4)
    }
}
