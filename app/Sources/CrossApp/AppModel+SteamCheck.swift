import CrossCore
import Foundation

/// Check Steam… on the Steam row: `Steam.check` (client, account, service, a test
/// program asking Steam for licences, each installed game's licence) off the main thread.
extension AppModel {
    func checkSteam(_ name: String) {
        guard let project, steamChecking.insert(name).inserted else { return }
        Task {
            defer { steamChecking.remove(name) }
            do {
                let check = try await Task.detached {
                    let (runtime, bottle) = try Runtime.loadBottle(name, in: project)
                    return Steam.check(in: bottle, runtime: runtime)
                }.value
                steamChecks[name] = check
            } catch {
                alertMessage = "Check Steam: \(error)"
            }
            await refreshSteamStatus(name)
        }
    }
}
