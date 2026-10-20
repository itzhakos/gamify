import AppKit
import CrossCore
import Foundation

/// Bottles kept outside the bottles folder (CrossCore Location.swift / Discover.swift):
/// Move to…, Eject, Mount, Remove from List, Find Bottles, and drives coming and going.
extension AppModel {
    /// "TestDrive" for a bottle kept on /Volumes/TestDrive/…, the folder's path for one
    /// kept elsewhere on this Mac, nil for a bottle in the bottles folder.
    func locationText(_ bottle: Bottle) -> String? {
        guard let location = bottle.location else { return nil }
        let parts = location.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] }
        return location.deletingLastPathComponent().path
    }

    /// Move to… on the bottle page: copies the bottle to `folder` (nil: the bottles
    /// folder), verifies the copy, switches over, removes the original.
    func moveBottle(_ name: String, to folder: URL?) {
        guard let bottle = bottle(named: name), let project, storageWork[name] == nil else { return }
        if isBusy(name) || !Steam.bottleProcesses(in: bottle).isEmpty || bottle.hasRunningServer {
            alertMessage = "Programs are running in '\(name)'. Quit them (or use Kill Bottle) before moving it."
            return
        }
        storageWork[name] = "Preparing…"
        Task.detached {
            let report: @Sendable (String) -> Void = { text in
                Task { @MainActor in self.storageWork[name] = text }
            }
            do {
                _ = try Runtime.forBottle(bottle, project: project).moveBottle(bottle, to: folder, progress: report)
            } catch {
                await MainActor.run { self.alertMessage = "\(name): \(error)" }
            }
            await MainActor.run {
                self.storageWork[name] = nil
                self.reloadBottles()
            }
            await self.refreshStorage(name)
        }
    }

    /// Eject: unmounts a disk-image bottle so the drive it is on can be disconnected.
    func ejectBottle(_ name: String) {
        guard let bottle = bottle(named: name), let project, storageWork[name] == nil else { return }
        if isBusy(name) {
            alertMessage = "Programs are running in '\(name)'. Quit them (or use Kill Bottle) before ejecting it."
            return
        }
        storageWork[name] = "Ejecting…"
        Task.detached {
            do {
                try Runtime.forBottle(bottle, project: project).ejectBottle(bottle)
            } catch {
                await MainActor.run { self.alertMessage = "\(name): \(error)" }
            }
            await MainActor.run {
                self.storageWork[name] = nil
                self.reloadBottles()
            }
        }
    }

    /// Mount on an ejected bottle's page: loading the bottle mounts its image again.
    func mountBottle(_ name: String) {
        guard let project else { return }
        storageWork[name] = "Mounting…"
        Task.detached {
            do {
                _ = try Bottle.load(name: name, in: project)
            } catch {
                await MainActor.run { self.alertMessage = "\(name): \(error)" }
            }
            await MainActor.run {
                self.storageWork[name] = nil
                self.reloadBottles()
            }
        }
    }

    /// Remove from List: the bottle leaves the sidebar, its files stay where they are.
    func forgetBottle(_ name: String) {
        guard let bottle = bottle(named: name), let project else { return }
        Task.detached {
            do {
                try Runtime(project: project, name: bottle.config.runtime).forgetBottle(bottle)
            } catch {
                await MainActor.run { self.alertMessage = "\(name): \(error)" }
            }
            await MainActor.run { self.reloadBottles() }
        }
    }

    /// Searches `folders` (nil: every connected local drive) for bottles, off the main thread.
    func findBottles(in folders: [URL]?) async -> [FoundBottle] {
        guard let project else { return [] }
        return await Task.detached {
            Bottle.find(in: folders ?? Bottle.searchableVolumes(), project: project)
        }.value
    }

    /// Add in Find Bottles: lists a found bottle under `name`.
    func addFoundBottle(_ found: FoundBottle, as name: String) async -> Bool {
        guard let project else { return false }
        let result = await Task.detached {
            Result { try Runtime(project: project).addBottle(at: found.url, name: name) }
        }.value
        switch result {
        case .success(let bottle):
            foundOnDrives.removeAll { $0.url == found.url }
            reloadBottles()
            selection = bottle.name
            return true
        case .failure(let error):
            alertMessage = "\(error)"
            return false
        }
    }

    /// Drives coming and going: the list is read again (a bottle on a drive that went
    /// away shows as not connected, one that came back works again), and a drive that
    /// was just connected is searched for bottles that are not listed yet.
    func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                guard let self else { return }
                if let volume { self.foundOnDrives.removeAll { $0.url.path.hasPrefix(volume.path + "/") } }
                self.reloadBottles()
            }
        }
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                guard let self else { return }
                self.reloadBottles()
                guard let volume, Bottle.searchableVolumes().contains(where: { $0.path == volume.path }) else { return }
                let found = await self.findBottles(in: [volume]).filter { $0.registeredAs == nil }
                let known = Set(self.foundOnDrives.map(\.url))
                self.foundOnDrives += found.filter { !known.contains($0.url) }
            }
        }
    }
}
