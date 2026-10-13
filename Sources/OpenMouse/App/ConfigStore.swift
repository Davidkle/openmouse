import Foundation
import Observation
import OpenMouseCore
import os

private let configLog = Logger(subsystem: "dev.openmouse", category: "config")

/// Loads and saves the JSON config in Application Support. Local only.
@MainActor
@Observable
final class ConfigStore {
    var config: Config {
        didSet {
            guard config != oldValue else { return }
            scheduleSave()
            onChange?(oldValue)
        }
    }

    @ObservationIgnored var onChange: ((Config) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private(set) var loadError: String?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenMouse", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    init() {
        let url = Self.fileURL
        if let data = try? Data(contentsOf: url) {
            do {
                config = try Config.decode(data)
            } catch {
                // Keep the unreadable file for the user and start fresh.
                let backup = url.deletingPathExtension().appendingPathExtension("invalid-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: backup)
                loadError = "Your config couldn't be read and was moved to \(backup.lastPathComponent)."
                configLog.error("Config decode failed: \(error.localizedDescription, privacy: .public)")
                config = Config()
            }
        } else {
            config = Config()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try config.encoded().write(to: Self.fileURL, options: .atomic)
        } catch {
            configLog.error("Config save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Edit the bindings for the global profile (`nil`) or an app profile.
    func setBinding(_ binding: ButtonBinding?, for button: ButtonID, profile: UUID?) {
        if let profile, let i = config.appProfiles.firstIndex(where: { $0.id == profile }) {
            config.appProfiles[i].bindings[button] = binding
        } else {
            config.bindings[button] = binding ?? .default
        }
    }

    func binding(for button: ButtonID, profile: UUID?) -> ButtonBinding {
        if let profile, let p = config.appProfiles.first(where: { $0.id == profile }) {
            return p.bindings[button] ?? config.bindings[button] ?? .default
        }
        return config.bindings[button] ?? .default
    }

    func isOverridden(_ button: ButtonID, profile: UUID?) -> Bool {
        guard let profile, let p = config.appProfiles.first(where: { $0.id == profile }) else { return false }
        return p.bindings[button] != nil
    }

    func updateDevice(_ name: String, _ change: (inout DeviceSettings) -> Void) {
        var settings = config.deviceSettings(for: name)
        change(&settings)
        config.devices[name] = settings
    }
}
