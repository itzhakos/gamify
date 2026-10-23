import AppKit
import CrossCore
import SwiftUI
import UniformTypeIdentifiers

/// The bottle page's Programs box: Install a Program… (any .exe/.msi installer), Add a
/// Program… (an exe inside C:), and the list from `Programs.list` (Start Menu / Desktop
/// shortcuts plus programs.json) with Launch and Remove per entry.
struct ProgramsBox: View {
    @EnvironmentObject var model: AppModel
    let bottle: Bottle
    @State private var adding: PickedExe?
    @State private var addName = ""
    @State private var addArguments = ""
    /// Clear Shader Cache… asks first.
    @State private var cacheToClear: ShaderCache.Entry?

    private var programs: [Program] { model.programs[bottle.name] ?? [] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if programs.isEmpty {
                    Text("No programs yet. Install a Program… runs an installer in this bottle and lists what it adds; Add a Program… picks an exe already in C:.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(programs) { program in
                                row(program)
                                if program.id != programs.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 118)
                }
                HStack {
                    Button("Install a Program…") { chooseInstaller() }
                    .help(HelpText.programsInstall)
                    Button("Add a Program…") { chooseExe() }
                        .help(HelpText.programsAdd)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(4)
        } label: {
            Label("Programs", systemImage: "square.grid.2x2")
        }
        .frame(minWidth: 260, maxWidth: .infinity)
        .sheet(item: $adding) { picked in
            addSheet(picked.url)
        }
        .alert("Clear the shader cache of \(cacheToClear?.name ?? "")?",
               isPresented: Binding(get: { cacheToClear != nil }, set: { if !$0 { cacheToClear = nil } }),
               presenting: cacheToClear) { entry in
            Button("Clear", role: .destructive) { model.clearShaderCache(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Deletes the shaders D3DMetal compiled for \(entry.name) (\(entry.sizeText), shared by every bottle). The next start compiles them again: a slower first start and some stutter. Apple recommends this when a game stops starting.")
        }
    }

    private func row(_ program: Program) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(program.name).fontWeight(.medium).lineLimit(1)
                Text(program.exe + (program.arguments.isEmpty ? "" : " " + program.arguments))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(HelpText.programPath(program.exe, shortcut: program.shortcut))
            }
            Spacer()
            Button("Launch") { model.launchProgram(program, in: bottle.name) }
                .controlSize(.small)
                .help(HelpText.programLaunch)
            Menu {
                let cache = model.shaderCache(for: program)
                Button(cache.map { "Clear Shader Cache (\($0.sizeText))…" } ?? "No Shader Cache Yet") {
                    cacheToClear = cache
                }
                .disabled(cache == nil)
                .help(HelpText.programClearShaderCache)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(HelpText.programMenu)
            Button {
                model.removeProgram(program, in: bottle.name)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(program.source == .shortcut ? HelpText.programRemoveShortcut : HelpText.programRemove)
        }
    }

    private func addSheet(_ exe: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a program to '\(bottle.name)'").font(.headline)
            Text(exe.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Form {
                TextField("Name", text: $addName)
                    .help(HelpText.addProgramName)
                TextField("Arguments", text: $addArguments, prompt: Text("optional"))
                    .help(HelpText.addProgramArguments)
            }
            HStack {
                Spacer()
                Button("Cancel") { adding = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addProgram(exe, name: addName.isEmpty ? nil : addName, arguments: addArguments, in: bottle.name)
                    adding = nil
                }
                .keyboardShortcut(.defaultAction)
                .help(HelpText.addProgramAdd)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Install a program in \(bottle.name)"
        panel.message = "Pick a Windows installer (.exe or .msi)"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe"), UTType(filenameExtension: "msi")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.installProgram(url, in: bottle.name)
    }

    private func chooseExe() {
        let panel = NSOpenPanel()
        panel.title = "Add a program from \(bottle.name)"
        panel.message = "Pick the program's .exe inside this bottle's C: drive"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = bottle.driveC.appendingPathComponent("Program Files")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addName = url.deletingPathExtension().lastPathComponent
        addArguments = ""
        adding = PickedExe(url: url)
    }
}

/// The exe picked for Add a Program… (drives the sheet).
struct PickedExe: Identifiable {
    let url: URL
    var id: String { url.path }
}
