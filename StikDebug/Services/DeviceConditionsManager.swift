// Real device conditions, with the FFI handles owned by a dedicated worker.
import Foundation
import Combine

final class DeviceConditionsManager: ObservableObject {
    static let shared = DeviceConditionsManager()

    @Published private(set) var groups: [DeviceConditionGroup] = []
    // Last enable acknowledged by ConditionInducer. The API cannot query the
    // actual current device condition, so this is not a verified thermal state.
    @Published private(set) var lastEnabled: DeviceConditionSelection?
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let worker = DispatchQueue(label: "com.stikdebug.conditions", qos: .userInitiated)
    private var connection: DeviceConditionsConnection? // worker queue only
    private var backgroundLease = false // main queue only
    private init() {}

    func dismissError() { errorMessage = nil }

    /// Revalidate the connection on screen entry or when returning to foreground.
    /// A stale UI must not keep displaying an active condition after disconnect.
    func connectIfNeeded() { refresh() }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        worker.async { [weak self] in
            guard let self else { return }
            do {
                if self.connection == nil {
                    self.connection = try JITEnableContext.shared.openDeviceConditionsConnection()
                }
                let groups = try self.connection!.availableConditions()
                DispatchQueue.main.async {
                    self.groups = groups
                    self.isConnected = true
                    self.isBusy = false
                }
            } catch {
                self.connection?.close()
                self.connection = nil
                DispatchQueue.main.async { self.reportDisconnected(error) }
            }
        }
    }

    func activate(groupID: String, profileID: String) {
        guard !isBusy, isConnected else { return }
        isBusy = true
        errorMessage = nil
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard let connection = self.connection else {
                    throw NSError(domain: "StikDebug.Conditions", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "No ConditionInducer connection"])
                }
                try connection.enable(groupID: groupID, profileID: profileID)
                DispatchQueue.main.async {
                    self.lastEnabled = DeviceConditionSelection(groupID: groupID, profileID: profileID)
                    self.updateBackgroundLease()
                    self.isBusy = false
                }
            } catch {
                self.connection?.close()
                self.connection = nil
                DispatchQueue.main.async { self.reportDisconnected(error) }
            }
        }
    }

    func disable() {
        guard !isBusy, lastEnabled != nil else { return }
        isBusy = true
        errorMessage = nil
        worker.async { [weak self] in
            guard let self else { return }
            do {
                try self.connection?.disable()
                DispatchQueue.main.async {
                    self.lastEnabled = nil
                    self.updateBackgroundLease()
                    self.isBusy = false
                }
            } catch {
                self.connection?.close()
                self.connection = nil
                DispatchQueue.main.async { self.reportDisconnected(error) }
            }
        }
    }

    func disconnect() {
        guard !isBusy else { return }
        isBusy = true
        worker.async { [weak self] in
            guard let self else { return }
            self.connection?.close()
            self.connection = nil
            DispatchQueue.main.async {
                self.lastEnabled = nil
                self.groups = []
                self.isConnected = false
                self.isBusy = false
                self.updateBackgroundLease()
            }
        }
    }

    private func reportDisconnected(_ error: Error) {
        lastEnabled = nil
        groups = []
        isConnected = false
        isBusy = false
        errorMessage = error.localizedDescription
        updateBackgroundLease()
        LogManager.shared.addErrorLog("Device Conditions: \(error.localizedDescription)")
    }

    /// Match 3.2.0's other long-lived sessions: both keep-alive strategies
    /// are reference-counted by upstream and obey the user's settings.
    private func updateBackgroundLease() {
        if lastEnabled != nil, !backgroundLease {
            backgroundLease = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        } else if lastEnabled == nil, backgroundLease {
            backgroundLease = false
            BackgroundAudioManager.shared.requestStop()
            BackgroundLocationManager.shared.requestStop()
        }
    }
}
