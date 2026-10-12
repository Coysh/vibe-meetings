import SwiftUI

// Reusable pieces built on `Tokens`. Pages compose these instead of restyling
// system controls one by one.

/// A small rounded label: folder, date, duration, organisation…
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color? = nil
    /// A trailing chevron, for chips that open a menu.
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(text).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous).strokeBorder(Tokens.stroke))
    }
}

/// The big serif title at the top of a page, with room on the right for actions.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.pageTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.secondary)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Tokens.Space.m)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// "Today", "Yesterday", "16 June 2026" — the label above a group of rows.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Tokens.sectionTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct HoverHighlight: ViewModifier {
    var isSelected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                     : AnyShapeStyle(hovering ? Tokens.hover : Color.clear))
            )
            .onHover { hovering = $0 }
    }
}

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Tokens.Space.l)
            .background(Tokens.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Tokens.stroke))
    }
}

extension View {
    /// Row feedback: a soft fill on hover, the accent tint when selected.
    func hoverHighlight(isSelected: Bool = false) -> some View {
        modifier(HoverHighlight(isSelected: isSelected))
    }

    /// A raised, hairline-bordered panel with padding.
    func card() -> some View {
        modifier(CardBackground())
    }
}

/// Capsule buttons: the accent for the main action, red for recording, a quiet
/// raised fill for everything else.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, record, secondary }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(kind: kind, configuration: configuration)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static func capsule(_ kind: CapsuleButtonStyle.Kind = .primary) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind)
    }
}

private struct CapsuleButtonBody: View {
    let kind: CapsuleButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(kind == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .secondary ? Tokens.stroke : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Color.accentColor)
        case .record: AnyShapeStyle(Tokens.record)
        case .secondary: AnyShapeStyle(Tokens.raised)
        }
    }
}

/// Text tabs with an accent underline that slides between them, room after
/// the last tab for an "add" button, and room on the right for the current
/// tab's actions. The tabs scroll sideways if there are too many to fit.
struct UnderlineTabBar<Tab: Hashable & Identifiable, AfterTabs: View, Trailing: View>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    @ViewBuilder var afterTabs: AfterTabs
    @ViewBuilder var trailing: Trailing
    @Namespace private var underline

    var body: some View {
        HStack(alignment: .bottom, spacing: Tokens.Space.l) {
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: Tokens.Space.xl) {
                    ForEach(tabs) { tab in
                        let isSelected = tab == selection
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { selection = tab }
                        } label: {
                            VStack(spacing: 6) {
                                Text(title(tab))
                                    .font(.system(.body).weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                                ZStack {
                                    Rectangle().fill(.clear)
                                    if isSelected {
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .matchedGeometryEffect(id: "underline", in: underline)
                                    }
                                }
                                .frame(height: 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    afterTabs
                        .padding(.bottom, 8)
                }
            }
            .scrollIndicators(.hidden)
            trailing
                .padding(.bottom, 6)
        }
        .background(alignment: .bottom) {
            Rectangle().fill(Tokens.stroke).frame(height: 1)
        }
    }
}

/// The capsule that floats at the bottom of a page: Start Recording, Resume
/// Recording, or the live recording controls.
struct FloatingActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            content
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.stroke))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
}

// MARK: - Floating bar on a page

extension View {
    /// Floats the recording controls at the bottom of the page while a meeting is
    /// being recorded (or starting). When nothing is recording it shows `idle` in
    /// a capsule — a page's main action, like "Resume Recording" — if `showsIdle`.
    func floatingActionBar<Idle: View>(showsIdle: Bool = true, @ViewBuilder idle: @escaping () -> Idle) -> some View {
        modifier(FloatingActionBarModifier(showsIdle: showsIdle, idle: idle))
    }

    /// Floats just the recording controls; nothing shows when idle.
    func floatingActionBar() -> some View {
        modifier(FloatingActionBarModifier<EmptyView>(showsIdle: false, idle: { EmptyView() }))
    }

    /// A notice that sits at the top of the main pane: a rounded card with a tint.
    func bannerCard(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        return self
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.m)
            .background(tint.opacity(0.12), in: shape)
            .background(Tokens.raised, in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.28)))
            .padding(.horizontal, Tokens.Space.l)
            .padding(.top, Tokens.Space.s)
    }
}

private struct FloatingActionBarModifier<Idle: View>: ViewModifier {
    let showsIdle: Bool
    let idle: () -> Idle
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let controller = env.activeRecordingController {
                RecordingBarView(controller: controller, onNavigateToMeeting: {
                    if let id = controller.meetingHandle?.meeting.id {
                        env.appRouter.selectMeetingID = id
                    }
                })
                .padding(.bottom, Tokens.Space.l)
                .frame(maxWidth: .infinity)
            } else if env.recordingService.isStarting {
                FloatingActionBar {
                    ProgressView().controlSize(.small)
                    Text("Starting recording…").foregroundStyle(.secondary)
                }
                .padding(.bottom, Tokens.Space.l)
                .frame(maxWidth: .infinity)
            } else if showsIdle {
                FloatingActionBar {
                    RecordingQuickSettingsButton()
                    idle()
                }
                    .padding(.bottom, Tokens.Space.l)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - People

/// Overlapping initials circles for the people in a meeting.
struct AvatarStack: View {
    let names: [String]
    var limit = 4
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(names.prefix(limit).enumerated()), id: \.offset) { index, name in
                Text(Self.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Self.color(for: name), in: Circle())
                    .overlay(Circle().strokeBorder(Tokens.surface, lineWidth: 2))
                    .zIndex(Double(limit - index))
                    .help(name)
            }
            if names.count > limit {
                Text("+\(names.count - limit)")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Tokens.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Tokens.stroke))
                    .help(names.dropFirst(limit).joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("People: " + names.joined(separator: ", "))
    }

    /// "Dalton Caldwell" → "DC"; "Michel" → "M".
    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.joined()
    }

    /// The same name is always the same colour.
    static func color(for name: String) -> Color {
        let palette: [Color] = [.green, .blue, .orange, .pink, .teal, .indigo, .mint, .brown]
        let hash = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}
