// Transom.swift — the notch channel, because macOS refused the banner one.
//
// UNUserNotificationCenter denies this app at registration and shows no
// prompt (SPEC section 10: five hypotheses killed by test, two left). So the
// visual half of the undock signal has never worked on this machine. Chimes
// carried it alone, and a chime cannot say WHICH drive is still mounted or WHO
// is holding it. It also cannot be read at all with the volume down.
//
// Transom runs on this Mac and takes a card in one POST. Same three sentences
// the notifier already writes, landing somewhere they are actually read.
//
// Local by construction: Transom binds 127.0.0.1 only, the token lives in
// DrivePark's Keychain item, and nothing in this file can reach the network. A
// missing Transom is not an error condition for DrivePark: no card is ever
// allowed to slow a park down, fail one, or change what a park reports.
//
// Off unless switched on, and a card carries only what it needs to (audit,
// Low, 2026-10-07). Through the token door: whether to undock, and which
// drives. Never which programs held them, their pids, or any path. Through
// the transom:// door, which any app can register for: a title with no names
// at all, and no message.

import Foundation
import Security

public enum Transom {
    /// Transom's local API. Loopback only; it is not reachable off this Mac.
    public static let endpoint = URL(string: "http://127.0.0.1:17893/")!
    /// The Keychain item Transom's own API docs name.
    public static let keychainLabel = "Transom Local API Token"

    private static let lock = NSLock()
    private static var cachedToken: String?
    private static var keychainReadable = true
    private static var failure: String?
    private static var channel: String?
    private static let queue = DispatchQueue(label: "com.wiltonblake.drivepark.transom")
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Why the last card did not arrive, or nil when the channel is healthy.
    ///
    /// Reported for the same reason Notifier reports its own refusal: a dead
    /// channel that looks alive is worse than no channel, because you stop
    /// checking the menu.
    public static var lastFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// Which door the last card went through, or nil before the first one.
    /// Read from the menu, so it must never touch the Keychain: that read can
    /// put a modal prompt on the main thread.
    public static var lastChannel: String? {
        lock.lock(); defer { lock.unlock() }
        return channel
    }

    private static func note(channel value: String) {
        lock.lock(); channel = value; lock.unlock()
    }

    private static func record(_ value: String?) {
        lock.lock(); failure = value; lock.unlock()
        Preferences.recordDiagnostic("transom", value ?? "ok")
    }

    // MARK: - The token

    /// Two sources, most explicit first. The environment is for scripts; the
    /// token a person pasted in lives in DrivePark's own Keychain item.
    ///
    /// Transom's Keychain item is NOT on this path. A cross-app Keychain read
    /// puts a modal password prompt on screen, and a park that stops to ask
    /// for a password is worse than a park with no card. `keychainToken()` is
    /// offered from the explicit "read it from the Keychain" action instead,
    /// where a human is already waiting on a dialog.
    public static func resolveToken() -> String? {
        lock.lock()
        if let cachedToken { lock.unlock(); return cachedToken }
        let mayReadKeychain = keychainReadable
        lock.unlock()

        guard let picked = pickToken(environment: ProcessInfo.processInfo.environment["TRANSOM_TOKEN"],
                                     mayReadKeychain: mayReadKeychain,
                                     keychain: { Preferences.transomToken }) else {
            Preferences.recordDiagnostic("transomTokenSource", mayReadKeychain
                ? "none found" : "Keychain not read: nobody at a terminal to answer its prompt")
            return nil
        }
        return cache(picked.token, source: picked.source)
    }

    /// The environment first, then DrivePark's Keychain item, and the
    /// Keychain only when this process may read it. Apart from
    /// `resolveToken` so a test can show the Keychain is never asked.
    static func pickToken(environment: String?, mayReadKeychain: Bool,
                          keychain: () -> String?) -> (token: String, source: String)? {
        if let environment, !environment.isEmpty { return (environment, "environment") }
        guard mayReadKeychain, let stored = keychain() else { return nil }
        return (stored, "keychain")
    }

    /// Stops this process from reading DrivePark's Keychain item, for the
    /// rest of its life.
    ///
    /// For `park now` with nobody at a terminal. The item is in the login
    /// keychain, which trusts only the binary that created it; any other
    /// binary gets an "allow access" dialog, and every `swift build` of the
    /// CLI is another binary. On 2026-10-10 that dialog came up three times
    /// from unattended test parks and held one CLI for 77 s, on the one path
    /// where nobody is there to answer it. Nothing can silence the dialog for
    /// a login-keychain item: kSecUseAuthenticationUIFail and an LAContext
    /// with interactionNotAllowed only apply to the Data Protection keychain
    /// ("Legacy keychain items will still activate UI if needed", SecItem.h),
    /// and SecKeychainSetUserInteractionAllowed has been deprecated since
    /// macOS 10.10. So the unattended CLI does not ask: TRANSOM_TOKEN in its
    /// environment if a script sets one, the transom:// door otherwise.
    public static func neverReadKeychain() {
        lock.lock(); keychainReadable = false; lock.unlock()
    }

    @discardableResult
    private static func cache(_ token: String, source: String) -> String {
        lock.lock(); cachedToken = token; lock.unlock()
        Preferences.recordDiagnostic("transomTokenSource", source)
        return token
    }

    /// Dropped on a 401 so a rotated token is picked up on the next card
    /// instead of requiring a relaunch.
    private static func invalidateToken() {
        lock.lock(); cachedToken = nil; lock.unlock()
    }

    /// Called after the stored token changes, so the next post uses the new one.
    public static func forgetCachedToken() {
        invalidateToken()
    }

    /// Best-effort read of Transom's own token, offered only from an explicit
    /// user action. Transom stores it under service com.transom.app / account
    /// local-api-token, and the ACL is Transom's, so macOS asks the user to
    /// approve this read. Returns nil on refusal, which is a normal answer.
    public static func keychainToken() -> String? {
        // Service + account first: that is how Transom's own documented shell
        // recipe reads it (security find-generic-password -s com.transom.app
        // -a local-api-token). The label is tried second because the API docs
        // name the item that way, and a label-only match found nothing here.
        let queries: [[String: Any]] = [
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "com.transom.app",
             kSecAttrAccount as String: "local-api-token"],
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrLabel as String: keychainLabel]
        ]
        var item: CFTypeRef?
        var status: OSStatus = errSecItemNotFound
        for query in queries {
            var q = query
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            q[kSecReturnData as String] = true
            status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess { break }
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            Preferences.recordDiagnostic("transomKeychain", "OSStatus \(status)")
            return nil
        }
        Preferences.recordDiagnostic("transomKeychain", "read")
        return token
    }

    // MARK: - Posting

    /// Fire and forget. Returns immediately; the park never waits on a card.
    ///
    /// - Parameter linkTitle: what the transom:// door shows instead of
    ///   `title`, for a title that names a drive. That door sends no message.
    public static func post(title: String,
                            message: String? = nil,
                            linkTitle: String? = nil,
                            symbol: String,
                            persistent: Bool = false,
                            duration: Int? = nil,
                            urgent: Bool = false) {
        guard Preferences.transomEnabled else { return }
        queue.async {
            _ = send(title: title, message: message, linkTitle: linkTitle, symbol: symbol,
                     persistent: persistent, duration: duration, urgent: urgent)
        }
    }

    /// For the CLI, which exits too fast for a detached post to land.
    @discardableResult
    public static func postAndWait(title: String,
                                   message: String? = nil,
                                   linkTitle: String? = nil,
                                   symbol: String,
                                   persistent: Bool = false,
                                   duration: Int? = nil,
                                   urgent: Bool = false) -> Bool {
        guard Preferences.transomEnabled else { return false }
        return send(title: title, message: message, linkTitle: linkTitle, symbol: symbol,
                    persistent: persistent, duration: duration, urgent: urgent)
    }

    private static func send(title: String,
                             message: String?,
                             linkTitle: String?,
                             symbol: String,
                             persistent: Bool,
                             duration: Int?,
                             urgent: Bool) -> Bool {
        guard let token = resolveToken() else {
            // No token, so take the other door. transom:// needs no
            // credential, which makes the notch work the moment DrivePark is
            // installed, at the cost of a receipt: LaunchServices reports that
            // the URL was handed over, never that a card appeared. Set a token
            // and the HTTP path takes over, with a real 200 behind it.
            if urgent {
                // Say it rather than swallow it. Transom honors priority on the
                // token'd door only, so without a token the one card that most
                // needs to interrupt is the one a Focus will hold.
                record("Posted by link, so a Focus will hold this. "
                       + "Set the Transom token to let do-not-undock cards through.")
            }
            return openViaURLScheme(title: linkTitle ?? title, symbol: symbol,
                                    persistent: persistent, duration: duration)
        }

        var body: [String: Any] = ["title": title, "symbol": symbol]
        if let message { body["message"] = message }
        if persistent { body["persistent"] = true }
        if let duration { body["duration"] = duration }
        // Rides Transom's urgent lane: through a Focus, still held by "VIPs and
        // codes only" and by Sleep. Only the two do-not-undock cards ask for it.
        if urgent { body["priority"] = "urgent" }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            record("Could not encode the card.")
            return false
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        var delivered = false
        var detail = "no response"
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                detail = error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 200 {
                delivered = true
                detail = "200"
                return
            }
            if http.statusCode == 401 { invalidateToken() }
            let reply = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            detail = "HTTP \(http.statusCode) \(reply)".trimmingCharacters(in: .whitespaces)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 4) == .timedOut {
            task.cancel()
            detail = "no answer from Transom within 4s"
        }

        if delivered {
            record(nil)
            note(channel: "api")
            Preferences.recordDiagnostic("transomChannel", "local API, confirmed")
        } else {
            record("Card not delivered: \(detail). Is Transom running?")
        }
        return delivered
    }

    /// The second door from Transom's docs: a URL anything can open.
    ///
    /// Used only when no token is configured. It can also launch Transom if it
    /// is not running, which is the correct outcome for a card that says do
    /// not unplug, and is why nothing here treats a closed Transom as an error.
    ///
    /// Any app can register for transom://, and whichever one macOS picks gets
    /// the whole URL. So this door carries the title alone, written by the
    /// caller to name no drive, and no message.
    private static func openViaURLScheme(title: String,
                                         symbol: String,
                                         persistent: Bool,
                                         duration: Int?) -> Bool {
        var pairs = ["title=" + encoded(title), "symbol=" + encoded(symbol)]
        if persistent { pairs.append("persistent=true") }
        if let duration { pairs.append("duration=\(duration)") }
        let url = "transom://post?" + pairs.joined(separator: "&")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            record("Could not open \(url.prefix(40))…: \(error.localizedDescription)")
            return false
        }
        guard process.terminationStatus == 0 else {
            record("Transom did not accept the link (open exited \(process.terminationStatus)). "
                   + "Is Transom installed?")
            return false
        }
        record(nil)
        note(channel: "link")
        Preferences.recordDiagnostic("transomChannel", "url scheme, unconfirmed")
        return true
    }

    /// Everything that is not unreserved gets encoded. Broader than strictly
    /// necessary and deliberately so: a blocker name is arbitrary text, and a
    /// stray & in a volume name must not become a second query parameter.
    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// One line for a menu or a terminal, honest in all three states.
    public static var statusLine: String {
        if !Preferences.transomEnabled { return "Notch cards: off" }
        if let failure = lastFailure { return "⚠︎ \(failure)" }
        switch lastChannel {
        case "link": return "Notch cards: on, by link, so they name no drive and a Focus holds them. Set a token for both."
        case "api": return "Notch cards: on, confirmed by Transom. Warnings pierce a Focus."
        default: return "Notch cards: on"
        }
    }
}
