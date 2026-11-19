import AppKit
import DeployCore
import SwiftUI
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published private(set) var state = StateFile()
    @Published private(set) var credential: Credential?
    @Published private(set) var code: DeviceCode?
    @Published private(set) var signingIn = false
    @Published private(set) var refreshing = false
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var reconnect = false
    @Published var message: String?
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "githubClientID") }
    }

    let api = GitHub()
    private var authorization: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var renewal: Task<Credential, Error>?
    private var generation = UUID()
    private var cooldown = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    private var storageOK = true
    private var refreshAgain = false

    init() {
        clientID = UserDefaults.standard.string(forKey: "githubClientID")
            ?? Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String ?? ""
        do { state = try StateFile.read() }
        catch { storageOK = false; message = "Could not load the watchlist. \(error.localizedDescription)" }
        do { credential = try Keychain.read() } catch { message = error.localizedDescription }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    func connect(using method: SignInMethod, personalToken: String = "") {
        cancelSignIn()
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard method != .app || !id.isEmpty else { return }
        signingIn = true
        message = nil
        authorization = Task {
            defer { if !Task.isCancelled { signingIn = false; code = nil } }
            do {
                let session: Credential
                switch method {
                case .cli:
                    let token = try await GitHubCLI.token()
                    session = try await .cli(login: api.login(token: token))
                case .personal:
                    let token = personalToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    session = try await .personal(token: token, login: api.login(token: token))
                case .app:
                    let device = try await api.begin(clientID: id)
                    try Task.checkCancellation()
                    code = device
                    let reply = try await api.authorize(clientID: id, code: device)
                    guard let token = reply.accessToken else { throw ServiceError.unauthorized }
                    session = try await reply.credential(clientID: id, login: api.login(token: token))
                }
                try Task.checkCancellation()
                try Keychain.save(session)
                invalidateSession()
                if state.login != session.login { state = StateFile(login: session.login) }
                credential = session
                persist()
                refresh()
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    func cancelSignIn() {
        authorization?.cancel()
        code = nil
        signingIn = false
    }

    func disconnect() {
        do {
            try Keychain.remove()
            cancelSignIn()
            invalidateSession()
            credential = nil
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func invalidateSession() {
        api.clearWorkflowCaches()
        generation = UUID()
        timer?.cancel()
        renewal?.cancel()
        renewal = nil
        errors = [:]
        cooldown = .distantPast
        reconnect = false
        refreshAgain = false
    }

    func token() async throws -> String {
        if Date() < cooldown { throw ServiceError.rateLimit(cooldown) }
        guard let credential, !reconnect else { throw ServiceError.unauthorized }
        if credential.signInMethod == .cli { return try await GitHubCLI.token(for: credential.login) }
        if let expiry = credential.expiration, expiry < Date().addingTimeInterval(90) {
            if let renewal { return try await renewal.value.accessToken }
            let version = generation
            let job = Task { () throws -> Credential in
                let updated = try await api.renew(credential)
                guard version == generation else { throw CancellationError() }
                try Keychain.save(updated)
                self.credential = updated
                return updated
            }
            renewal = job
            defer { if version == generation { renewal = nil } }
            return try await job.value.accessToken
        }
        return credential.accessToken
    }

    func record(_ error: Error) {
        if case ServiceError.rateLimit(let until) = error { cooldown = until }
        if case ServiceError.unauthorized = error { reconnect = true }
    }

    func rememberRepository(_ repository: String) {
        guard state.lastRepository != repository else { return }
        state.lastRepository = repository
        persist()
    }

    func follow(_ watches: [Watch]) {
        guard state.add(watches) else { return }
        persist()
        refresh()
    }

    func setFilter(_ filter: WorkflowFilter?, for id: UUID) {
        guard state.setFilter(filter, for: id) else { return }
        errors[id] = nil
        persist()
        refresh()
    }

    func rename(_ id: UUID, to displayName: String) {
        guard state.rename(id, to: displayName) else { return }
        persist()
    }

    func unfollow(_ watch: Watch) {
        state.watches.removeAll { $0.id == watch.id }
        state.readings[watch.id] = nil
        errors[watch.id] = nil
        persist()
    }

    func toggle(_ kind: AlertKind, for id: UUID, enabled: Bool) async {
        if enabled {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                    message = "Allow Deploy Status notifications in System Settings to enable this alert."
                    return
                }
            } catch { message = error.localizedDescription; return }
        }
        guard let index = state.watches.firstIndex(where: { $0.id == id }) else { return }
        if enabled { state.watches[index].alerts.insert(kind) }
        else { state.watches[index].alerts.remove(kind) }
        persist()
    }

    private func persist() {
        guard storageOK else { return }
        do { try state.save() } catch { message = error.localizedDescription }
    }

    func refresh() {
        timer?.cancel()
        if refreshing { refreshAgain = true; return }
        guard credential != nil, !reconnect, !state.watches.isEmpty else { return }
        if Date() < cooldown { schedule(); return }
        refreshing = true
        Task { await runPoll() }
    }

    private func schedule() {
        guard credential != nil, !reconnect, !state.watches.isEmpty else { return }
        let busy = state.readings.values.contains { $0.needsFrequentPolling }
        let delay = max(busy ? 15.0 : 60.0, cooldown.timeIntervalSinceNow)
        timer = Task {
            do { try await Task.sleep(for: .seconds(delay)); refresh() } catch {}
        }
    }

    private func runPoll() async {
        let version = generation
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; refresh() } else { schedule() }
        }
        do {
            let access = try await token()
            let groups = Dictionary(grouping: state.watches, by: \.repository)
            for (repo, watches) in groups {
                guard version == generation else { return }
                var shared: [Deployment] = []
                var deploymentError: Error?
                do {
                    if watches.contains(where: { $0.workflowID == nil }) {
                        shared = try await api.deployments(repo: repo, token: access)
                    }
                } catch {
                    guard version == generation else { return }
                    record(error)
                    for watch in watches where watch.workflowID == nil { errors[watch.id] = error.localizedDescription }
                    if reconnect || Date() < cooldown { break }
                    deploymentError = error
                }
                for watch in watches {
                    if watch.workflowID == nil && deploymentError != nil { continue }
                    guard version == generation else { return }
                    do {
                        let previous = state.readings[watch.id] ?? Reading()
                        let (reading, events) = try await api.poll(watch, shared: shared, previous: previous, token: access)
                        guard version == generation else { return }
                        guard let current = state.watches.first(where: { $0.id == watch.id }), current.runFilter == watch.runFilter else { continue }
                        state.readings[watch.id] = reading
                        errors[watch.id] = nil
                        persist()
                        for event in events where event.alert.map(current.alerts.contains) == true {
                            let content = UNMutableNotificationContent()
                            content.title = "\(current.service) • \(current.stage)"
                            content.body = "\(event.phase.label) at \(event.date.formatted(date: .abbreviated, time: .standard))"
                            let request = UNNotificationRequest(identifier: "\(current.id)-\(event.id)", content: content, trigger: nil)
                            do { try await UNUserNotificationCenter.current().add(request) }
                            catch { message = error.localizedDescription }
                        }
                    } catch {
                        guard version == generation else { return }
                        guard state.watches.contains(where: { $0.id == watch.id && $0.runFilter == watch.runFilter }) else { continue }
                        record(error)
                        errors[watch.id] = error.localizedDescription
                        if reconnect || Date() < cooldown { return }
                    }
                }
            }
        } catch {
            guard version == generation else { return }
            record(error)
            for watch in state.watches { errors[watch.id] = error.localizedDescription }
        }
    }
}
