import AppKit
import SwiftUI

enum InputFeedbackPhase { case working, information, failure }

/// A request owns its notice. Late completions cannot revive a dismissed notice
/// or replace feedback belonging to a more recent request.
@MainActor final class InputFeedbackState: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var detail = ""
    @Published private(set) var phase: InputFeedbackPhase = .working
    private(set) var id: UUID?
    private(set) var pid: pid_t = 0
    var anchor: NSRect?

    @discardableResult func begin(pid: pid_t) -> UUID {
        let id = UUID(); self.id = id; self.pid = pid; anchor = nil
        message = "正在读取输入…"; detail = ""; phase = .working
        return id
    }
    @discardableResult func update(_ id: UUID, message: String, detail: String = "", phase: InputFeedbackPhase) -> Bool {
        guard self.id == id else { return false }
        self.message = message; self.detail = detail; self.phase = phase
        return true
    }
    func dismiss(_ id: UUID? = nil) {
        guard id == nil || self.id == id else { return }
        self.id = nil
    }
}

@MainActor struct InputFeedbackView: View {
    @ObservedObject var state: InputFeedbackState
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if state.phase == .working { ProgressView().controlSize(.small).padding(.top, 2) }
            else {
                Image(systemName: state.phase == .failure ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(state.phase == .failure ? Color.orange : Color.secondary).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(state.message).font(.callout.weight(.medium)).lineLimit(3)
                if !state.detail.isEmpty { Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14).frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary)).padding(3)
        .accessibilityElement(children: .combine)
    }
}
