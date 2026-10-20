import AppKit
import CrossCore
import SwiftUI

/// Find Bottles: searches the connected drives (or a chosen folder) for bottles that are
/// not in the list, e.g. on a drive brought over from another Mac, and adds them
/// (CrossCore Discover.swift). Images are looked into read-only.
struct FindBottlesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var found: [FoundBottle] = []
    @State private var searched: [URL] = []
    @State private var searching = false
    /// Name to add each bottle under, by path (editable when the name is taken).
    @State private var names: [String: String] = [:]
    @State private var adding: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Bottles").font(.headline)
            Text("Looks through every connected drive (three folder levels deep), or a folder you choose, for Gamify bottles that are not in the list: bottle folders and disk images. A bottle added from a drive runs from there, like one created there; it shows as not connected while the drive is away.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if searching {
                    ProgressView().controlSize(.small)
                    Text("Searching \(searched.map(\.lastPathComponent).joined(separator: ", "))…").foregroundStyle(.secondary)
                } else {
                    Text(searched.isEmpty ? "No drives connected." : "Searched \(searched.map(\.path).joined(separator: ", ")).")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Search Drives Again") { search(nil) }.disabled(searching)
                Button("Search a Folder…", action: chooseFolder).disabled(searching)
            }
            .font(.callout)
            List {
                if found.isEmpty && !searching {
                    Text("No bottles found.").foregroundStyle(.secondary)
                }
                ForEach(found) { f in
                    row(f)
                }
            }
            .frame(minHeight: 220)
        }
        .padding()
        .frame(width: 640, height: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { search(nil) }
        .onDisappear { model.foundOnDrives = [] }   // reviewed: the sidebar banner goes away
    }

    private func row(_ f: FoundBottle) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: f.isImage ? "internaldrive" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.suggestedName).fontWeight(.medium)
                Text(f.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(details(f)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let listed = f.registeredAs {
                Text("listed as '\(listed)'").font(.callout).foregroundStyle(.secondary)
            } else if adding.contains(f.id) {
                ProgressView().controlSize(.small)
            } else {
                let name = names[f.id] ?? f.suggestedName
                TextField("Name", text: Binding(get: { name }, set: { names[f.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("Add") { add(f, as: name) }
                    .disabled(model.newBottleNameError(name) != nil || name.isEmpty)
                    .help(model.newBottleNameError(name) ?? "List this bottle; it stays where it is")
            }
        }
        .padding(.vertical, 2)
    }

    private func details(_ f: FoundBottle) -> String {
        let kind = f.isImage ? "disk image" : "folder"
        guard let config = f.config else { return kind }
        let size = config.storage.map { ", \($0.sizeGB) GB" } ?? ""
        return "\(kind)\(size) · \(config.runtime) · \(config.graphics.rawValue)"
    }

    private func search(_ folders: [URL]?) {
        searching = true
        searched = folders ?? Bottle.searchableVolumes()
        Task {
            found = await model.findBottles(in: searched)
            searching = false
        }
    }

    private func add(_ f: FoundBottle, as name: String) {
        adding.insert(f.id)
        Task {
            if await model.addFoundBottle(f, as: name) {
                found = await model.findBottles(in: searched)
            }
            adding.remove(f.id)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Search a folder for bottles"
        panel.prompt = "Search"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { search([url]) }
    }
}
