// Device Conditions: owns an independent RSD connection instead of retaining
// the shared adapter that JITEnableContext.startTunnel() can replace.
import Foundation
import idevice

struct DeviceConditionProfile: Identifiable, Hashable {
    let id: String
    let title: String
}

struct DeviceConditionGroup: Identifiable {
    let id: String
    let profiles: [DeviceConditionProfile]
}

struct DeviceConditionSelection: Equatable {
    let groupID: String
    let profileID: String
}

/// Used only on DeviceConditionsManager's serial worker queue.
final class DeviceConditionsConnection {
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var inducer: OpaquePointer?
    private var isActive = false

    init(adapter: OpaquePointer, handshake: OpaquePointer,
         remoteServer: OpaquePointer, inducer: OpaquePointer) {
        self.adapter = adapter
        self.handshake = handshake
        self.remoteServer = remoteServer
        self.inducer = inducer
    }

    deinit { close() }

    private func error(_ message: String) -> NSError {
        NSError(domain: "StikDebug.Conditions", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func ffiError(_ pointer: UnsafeMutablePointer<IdeviceFfiError>, _ fallback: String) -> NSError {
        let message = pointer.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        let code = Int(pointer.pointee.code)
        idevice_error_free(pointer)
        return NSError(domain: "StikDebug.Conditions", code: code,
                       userInfo: [NSLocalizedDescriptionKey: "\(fallback): \(message)"])
    }

    func availableConditions() throws -> [DeviceConditionGroup] {
        guard let inducer else { throw error("ConditionInducer is disconnected") }
        var rawGroups: UnsafeMutablePointer<UnsafeMutablePointer<IdeviceConditionGroup>?>?
        var count: UInt = 0
        if let failed = condition_inducer_available_conditions(inducer, &rawGroups, &count) {
            throw ffiError(failed, "Failed to list conditions")
        }
        defer { condition_inducer_groups_free(rawGroups, count) }
        guard count <= 1024 else { throw error("Too many condition groups returned") }
        guard let rawGroups else {
            if count == 0 { return [] }
            throw error("ConditionInducer returned no group array")
        }

        var result: [DeviceConditionGroup] = []
        for index in 0..<Int(count) {
            guard let rawGroup = rawGroups[index] else { continue }
            let group = rawGroup.pointee
            guard let groupID = group.identifier.flatMap({ String(validatingUTF8: $0) }),
                  !groupID.isEmpty else { continue }
            guard group.profiles_count <= 1024 else { throw error("Too many condition profiles returned") }
            var profiles: [DeviceConditionProfile] = []
            if let rawProfiles = group.profiles {
                for i in 0..<Int(group.profiles_count) {
                    let profile = rawProfiles[i]
                    guard let profileID = profile.identifier.flatMap({ String(validatingUTF8: $0) }),
                          !profileID.isEmpty else { continue }
                    let description = profile.description.flatMap({ String(validatingUTF8: $0) })
                    let title = (description?.isEmpty == false) ? description! : profileID
                    profiles.append(DeviceConditionProfile(id: profileID, title: title))
                }
            }
            result.append(DeviceConditionGroup(id: groupID, profiles: profiles))
        }
        return result
    }

    func enable(groupID: String, profileID: String) throws {
        guard let inducer else { throw error("ConditionInducer is disconnected") }
        if isActive { try disable() }
        let failed = groupID.withCString { group in
            profileID.withCString { profile in
                condition_inducer_enable(inducer, group, profile)
            }
        }
        if let failed { throw ffiError(failed, "Failed to enable condition") }
        isActive = true
    }

    func disable() throws {
        guard let inducer else { throw error("ConditionInducer is disconnected") }
        guard isActive else { return }
        if let failed = condition_inducer_disable(inducer) {
            throw ffiError(failed, "Failed to disable condition")
        }
        isActive = false
    }

    func close() {
        if let inducer {
            if isActive, let failed = condition_inducer_disable(inducer) {
                idevice_error_free(failed)
            }
            condition_inducer_free(inducer)
            self.inducer = nil
        }
        isActive = false
        if let remoteServer { remote_server_free(remoteServer); self.remoteServer = nil }
        if let handshake { rsd_handshake_free(handshake); self.handshake = nil }
        if let adapter { adapter_free(adapter); self.adapter = nil }
    }
}
