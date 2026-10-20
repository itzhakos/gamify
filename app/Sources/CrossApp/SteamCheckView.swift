import AppKit
import CrossCore
import SwiftUI

/// The result of Check Steam…: the client (running, signed in, online, the Steam Client
/// Service, whether a test program gets licences from Steam), every installed game's
/// licence, and how to launch games so Steam counts the licence.
struct SteamCheckSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let bottle: String

    private var check: Steam.Check? { model.steamChecks[bottle] }
    private var checking: Bool { model.steamChecking.contains(bottle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Steam check").font(.title2).fontWeight(.semibold)
                Text("· \(bottle)").font(.title2).foregroundStyle(.secondary)
                Spacer()
                if checking { ProgressView().controlSize(.small) }
            }
            if let check {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Steam", check.client)
                        section("Installed games", check.apps.map(\.item),
                                empty: "No games installed in this bottle yet.")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How to launch").font(.headline)
                            Text(check.launchAdvice).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Checked \(Steam.Status.timeText(check.checked)). The test program runs as Spacewar (app \(Steam.probeAppID), free for every account) for a second; nothing in the account changes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(checking ? "Asking Steam…" : "Not checked yet.").foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(check?.text ?? "", forType: .string)
                }
                .disabled(check == nil)
                Spacer()
                Button("Check Again") { model.checkSteam(bottle) }
                    .disabled(checking)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }

    private func section(_ title: String, _ items: [Steam.CheckItem], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if items.isEmpty, let empty { Text(empty).foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(item.level).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).fontWeight(.medium)
                        Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func icon(_ level: Steam.CheckItem.Level) -> some View {
        switch level {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
