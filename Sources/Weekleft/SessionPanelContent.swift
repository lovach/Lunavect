import SwiftUI

@MainActor final class SessionPanelState: ObservableObject {
    @Published var isVisible: Bool
    init(isVisible: Bool = false) { self.isVisible = isVisible }
}

/// Remove the timeline and row hierarchy while hidden. SessionsView's filter
/// state remains outside this boundary and survives closing the popover.
struct SessionPanelContent<Content: View>: View {
    @ObservedObject var state: SessionPanelState
    @ViewBuilder var content: () -> Content
    var body: some View {
        if state.isVisible { content() }
    }
}
