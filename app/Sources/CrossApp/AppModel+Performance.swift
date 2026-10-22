import CrossCore
import Foundation

/// The Performance box on the bottle page and Clear Shader Cache… in the Programs box.
extension AppModel {
    /// Saves the bottle's performance settings to cross.json; they apply to programs
    /// started afterwards. MetalFX and Retina also need files and registry values in the
    /// bottle, put in place off the main thread (`Runtime.applyPerformance`).
    func setPerformance(_ performance: PerformanceSettings, for name: String) {
        guard var bottle = bottle(named: name), bottle.config.performance != performance else { return }
        let old = bottle.config.performance
        bottle.config.performance = performance
        do {
            try bottle.saveConfig()
        } catch {
            alertMessage = "\(error)"
            return
        }
        reloadBottles()
        if old.metalfx != performance.metalfx || old.retina != performance.retina {
            applyPerformance(to: bottle)
        }
    }

    /// `Runtime.applyPerformance` in the background (it may run regedit for a second).
    /// `force`: write the registry values even when the bottle's registry files already
    /// show them (they lag behind a running wineserver).
    func applyPerformance(to bottle: Bottle, force: Bool = true) {
        guard let project else { return }
        Task.detached {
            do {
                let runtime = try Runtime.forBottle(bottle, project: project)
                try runtime.applyPerformance(to: bottle, force: force)
            } catch {
                await MainActor.run { self.alertMessage = "\(bottle.name): \(error)" }
            }
        }
    }

    /// The shader cache folder of a program's exe, nil when D3DMetal has not made one.
    func shaderCache(for program: Program) -> ShaderCache.Entry? {
        shaderCaches[ShaderCache.exeName(program.exe).lowercased()]
    }

    func clearShaderCache(_ entry: ShaderCache.Entry) {
        do {
            try ShaderCache.clear(exe: entry.name)
        } catch {
            alertMessage = "Could not clear the shader cache of \(entry.name): \(error)"
        }
        shaderCaches[entry.name.lowercased()] = nil
    }
}
