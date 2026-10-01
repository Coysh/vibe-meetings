import SwiftUI
import VMCalendar
import VMCore

/// Small capsule naming the platform of an event's join link ("Teams",
/// "Zoom", "Google Meet", "Webex"). Renders nothing for events without one.
struct PlatformBadge: View {
    let event: CalendarEvent

    var body: some View {
        if let platform = event.meetingLink?.platform {
            Text(platform.displayName)
                .font(.caption2.bold())
                .foregroundStyle(platform.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(platform.tint.opacity(0.15), in: Capsule())
        }
    }
}

extension MeetingPlatform {
    var tint: Color {
        switch self {
        case .teams: .purple
        case .zoom: .blue
        case .googleMeet: .green
        case .webex: .teal
        case .other: .secondary
        }
    }
}
