import Darwin
import CryptoKit
import Foundation
import Network
import Security
import SystemConfiguration

final class MobileDashboardHTTPServer {
    enum State: Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    typealias StateHandler = @Sendable (State) -> Void
    typealias ViewerCountHandler = @Sendable (Int) -> Void

    static let pwaBootstrapCookieName =
        "ai_quota_pwa_bootstrap"
    static let pwaInstallCookieName =
        "ai_quota_pwa_install"
    static let pwaBootstrapLifetime: TimeInterval = 60 * 60
    static let maximumOutstandingPWABootstraps = 16
    static let pwaInstallCredentialLifetime: TimeInterval =
        30 * 24 * 60 * 60
    static let pwaInstallAuthorizationScheme = "PWAInstall"
    static let manualPairingCodeLength = 8
    static let maximumManualClaimBodySize = 256
    static let permissionsPolicy =
        "camera=(), geolocation=(), microphone=(), payment=(), "
        + "usb=(), screen-wake-lock=(self)"
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        + "connect-src 'self' http:; img-src 'self' data:; "
        + "media-src 'self'; manifest-src 'self'; worker-src 'self'; "
        + "base-uri 'none'; frame-ancestors 'none'; form-action 'none'"

    private let queue = DispatchQueue(
        label: "com.techfanseric.aiquotabar.mobile-dashboard")
    private let stateHandler: StateHandler
    private let viewerCountHandler: ViewerCountHandler
    private let dateProvider: @Sendable () -> Date
    private let pwaBootstrapMaxAge: Int
    private let pwaInstallMaxAge: Int
    private let pwaInstallCredentialLifetime: TimeInterval
    private let sensitiveCORSHostProvider:
        @Sendable () -> Set<String>
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var eventConnections: [ObjectIdentifier: NWConnection] = [:]
    private var eventSendsInFlight: Set<ObjectIdentifier> = []
    private var latestQueuedEvent: [ObjectIdentifier: Data] = [:]
    private var requestTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var pwaClaimBroker: MobileDashboardPWAClaimBroker
    private var manualPairingBroker =
        MobileDashboardManualPairingBroker()
    private var requiresPairingCode = true
    private var colorScheme: MobileDashboardColorScheme = .automatic
    private var serverInstanceID = ""
    private var staticResources: [String: StaticResource] = [:]
    private let maximumConnectionCount = 32
    private let maximumViewerCount = 8
    private let maximumRequestHeaderSize = 16_384
    private let maximumRequestBodySize = 1_024
    private let requestHeaderTimeout: TimeInterval = 8

    init(
        stateHandler: @escaping StateHandler,
        viewerCountHandler: @escaping ViewerCountHandler,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        pwaBootstrapLifetime: TimeInterval =
            MobileDashboardHTTPServer.pwaBootstrapLifetime,
        pwaInstallCredentialLifetime: TimeInterval =
            MobileDashboardHTTPServer.pwaInstallCredentialLifetime,
        maximumOutstandingPWABootstraps: Int =
            MobileDashboardHTTPServer.maximumOutstandingPWABootstraps,
        sensitiveCORSHostProvider:
            @escaping @Sendable () -> Set<String> = {
                MobileDashboardHTTPServer.currentAccessHosts()
            }
    ) {
        self.stateHandler = stateHandler
        self.viewerCountHandler = viewerCountHandler
        self.dateProvider = dateProvider
        pwaBootstrapMaxAge = max(
            1,
            Int(pwaBootstrapLifetime))
        self.pwaInstallCredentialLifetime = max(
            1,
            pwaInstallCredentialLifetime)
        pwaInstallMaxAge = max(
            1,
            Int(min(
                self.pwaInstallCredentialLifetime,
                TimeInterval(Int32.max))))
        self.sensitiveCORSHostProvider = sensitiveCORSHostProvider
        pwaClaimBroker = MobileDashboardPWAClaimBroker(
            lifetime: pwaBootstrapLifetime,
            maximumOutstanding: maximumOutstandingPWABootstraps)
    }

    func start(
        port: UInt16,
        accessToken: String,
        colorScheme: MobileDashboardColorScheme = .automatic,
        requiresPairingCode: Bool = true,
        manualPairingCode: String? = nil,
        manualPairingCodeExpiresAt: Date? = nil
    ) {
        queue.async { [weak self] in
            self?.startOnQueue(
                port: port,
                accessToken: accessToken,
                colorScheme: colorScheme,
                requiresPairingCode: requiresPairingCode,
                manualPairingCode: manualPairingCode,
                manualPairingCodeExpiresAt:
                    manualPairingCodeExpiresAt)
        }
    }

    func updateColorScheme(
        _ colorScheme: MobileDashboardColorScheme
    ) {
        queue.async { [weak self] in
            self?.colorScheme = colorScheme
        }
    }

    func updatePairingPolicy(
        requiresPairingCode: Bool,
        manualPairingCode: String?,
        manualPairingCodeExpiresAt: Date?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requiresPairingCode = requiresPairingCode
            self.manualPairingBroker.reset(
                code: requiresPairingCode
                    ? manualPairingCode
                    : nil,
                expiresAt: requiresPairingCode
                    ? manualPairingCodeExpiresAt
                    : nil)
        }
    }

    func updateManualPairingCode(
        _ code: String,
        expiresAt: Date
    ) {
        queue.async { [weak self] in
            self?.manualPairingBroker.reset(
                code: code,
                expiresAt: expiresAt)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue(notifyState: true)
        }
    }

    func broadcast(snapshotData: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = Data("data: ".utf8)
                + snapshotData
                + Data("\n\n".utf8)
            for connection in self.eventConnections.values {
                self.sendEvent(payload, to: connection)
            }
        }
    }

    func sendHeartbeat() {
        queue.async { [weak self] in
            guard let self else { return }
            let heartbeat = Data(": heartbeat\n\n".utf8)
            for connection in self.eventConnections.values {
                self.sendEvent(heartbeat, to: connection)
            }
        }
    }

    private func startOnQueue(
        port: UInt16,
        accessToken: String,
        colorScheme: MobileDashboardColorScheme,
        requiresPairingCode: Bool,
        manualPairingCode: String?,
        manualPairingCodeExpiresAt: Date?
    ) {
        stopOnQueue(notifyState: false)
        stateHandler(.starting)

        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            stateHandler(.failed("Port \(port) is invalid."))
            return
        }

        do {
            staticResources = try Self.loadStaticResources()
            pwaClaimBroker.reset(accessToken: accessToken)
            self.colorScheme = colorScheme
            self.requiresPairingCode = requiresPairingCode
            serverInstanceID = Self.generateRandomBase64URL(
                byteCount: 16) ?? ""
            manualPairingBroker.reset(
                code: requiresPairingCode
                    ? manualPairingCode
                    : nil,
                expiresAt: requiresPairingCode
                    ? manualPairingCodeExpiresAt
                    : nil)

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            let listener = try NWListener(
                using: parameters,
                on: networkPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    self.handleListenerState(state, port: port)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
        } catch {
            stateHandler(.failed(error.localizedDescription))
        }
    }

    private func stopOnQueue(notifyState: Bool) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for timeout in requestTimeouts.values {
            timeout.cancel()
        }
        requestTimeouts.removeAll()
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        let hadViewers = !eventConnections.isEmpty
        connections.removeAll()
        eventConnections.removeAll()
        eventSendsInFlight.removeAll()
        latestQueuedEvent.removeAll()
        pwaClaimBroker.reset(accessToken: "")
        manualPairingBroker.reset(code: nil, expiresAt: nil)
        requiresPairingCode = true
        colorScheme = .automatic
        serverInstanceID = ""
        staticResources = [:]
        if hadViewers {
            viewerCountHandler(0)
        }
        if notifyState {
            stateHandler(.stopped)
        }
    }

    private func handleListenerState(
        _ state: NWListener.State,
        port: UInt16
    ) {
        switch state {
        case .setup, .waiting:
            stateHandler(.starting)
        case .ready:
            stateHandler(.ready(port: port))
        case let .failed(error):
            stopOnQueue(notifyState: false)
            stateHandler(.failed(error.localizedDescription))
        case .cancelled:
            break
        @unknown default:
            stateHandler(.failed("The local network listener entered an unknown state."))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isAllowedLocalEndpoint(connection.endpoint),
              connections.count < maximumConnectionCount else {
            connection.cancel()
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.removeConnection(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  self.connections[identifier] != nil else {
                return
            }
            self.respond(
                status: "408 Request Timeout",
                contentType: "text/plain; charset=utf-8",
                body: Data("Request headers timed out.".utf8),
                to: connection)
        }
        requestTimeouts[identifier] = timeout
        queue.asyncAfter(
            deadline: .now() + requestHeaderTimeout,
            execute: timeout)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(
        from connection: NWConnection,
        buffer: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.queue.async {
                var nextBuffer = buffer
                if let data {
                    nextBuffer.append(data)
                }

                guard let headerRange = nextBuffer.range(
                    of: Data("\r\n\r\n".utf8)) else {
                    if nextBuffer.count > self.maximumRequestHeaderSize {
                        self.cancelRequestTimeout(for: connection)
                        self.respond(
                            status:
                                "431 Request Header Fields Too Large",
                            contentType: "text/plain; charset=utf-8",
                            body: Data(
                                "Request headers are too large.".utf8),
                            to: connection)
                        return
                    }
                    if isComplete || error != nil {
                        self.cancelRequestTimeout(for: connection)
                        connection.cancel()
                        return
                    }
                    self.receiveRequest(
                        from: connection,
                        buffer: nextBuffer)
                    return
                }

                if headerRange.lowerBound
                    > self.maximumRequestHeaderSize {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "431 Request Header Fields Too Large",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Request headers are too large.".utf8),
                        to: connection)
                    return
                }

                let headerData = nextBuffer.subdata(
                    in: 0..<headerRange.lowerBound)
                guard let headerText = String(
                    data: headerData,
                    encoding: .utf8) else {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Invalid request headers.".utf8),
                        to: connection)
                    return
                }
                let headerLines = headerText.components(
                    separatedBy: "\r\n")
                let headers = Self.parseHeaders(
                    Array(headerLines.dropFirst()))
                guard headers["transfer-encoding"] == nil else {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: Data(
                            "Transfer-Encoding is not supported.".utf8),
                        to: connection)
                    return
                }
                let bodyLength: Int
                if let contentLength = headers["content-length"] {
                    guard let length = Self.strictNonnegativeInt(
                        Substring(contentLength)) else {
                        self.cancelRequestTimeout(for: connection)
                        self.respond(
                            status: "400 Bad Request",
                            contentType: "text/plain; charset=utf-8",
                            body: Data("Invalid Content-Length.".utf8),
                            to: connection)
                        return
                    }
                    bodyLength = length
                } else {
                    bodyLength = 0
                }
                guard bodyLength <= self.maximumRequestBodySize else {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "413 Payload Too Large",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("Request body is too large.".utf8),
                        to: connection)
                    return
                }
                let expectedLength = headerRange.upperBound + bodyLength
                if nextBuffer.count == expectedLength {
                    self.handleRequest(nextBuffer, connection: connection)
                    return
                }
                if nextBuffer.count > expectedLength {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: Data(
                            "HTTP pipelining is not supported.".utf8),
                        to: connection)
                    return
                }
                if isComplete || error != nil {
                    self.cancelRequestTimeout(for: connection)
                    self.respond(
                        status: "400 Bad Request",
                        contentType: "text/plain; charset=utf-8",
                        body: Data("The request body is incomplete.".utf8),
                        to: connection)
                    return
                }

                self.receiveRequest(
                    from: connection,
                    buffer: nextBuffer)
            }
        }
    }

    private func handleRequest(
        _ data: Data,
        connection: NWConnection
    ) {
        cancelRequestTimeout(for: connection)
        guard let headerRange = data.range(
                of: Data("\r\n\r\n".utf8)),
              let headerText = String(
                data: data.subdata(in: 0..<headerRange.lowerBound),
                encoding: .utf8) else {
            respond(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: Data("The request could not be read.".utf8),
                to: connection)
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3 else {
            respond(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: Data("The request line is invalid.".utf8),
                to: connection)
            return
        }

        let method = String(requestParts[0])
        let rawTarget = String(requestParts[1])
        guard let components = URLComponents(string: rawTarget) else {
            respond(
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                body: Data("The request target is invalid.".utf8),
                to: connection,
                sendsBody: method != "HEAD")
            return
        }
        let path = components.path
        let headers = Self.parseHeaders(Array(lines.dropFirst()))
        let requestBody = data.subdata(
            in: headerRange.upperBound..<data.count)

        if method == "OPTIONS" {
            switch path {
            case "/api/v1/health":
                handleHealthPreflight(
                    headers: headers,
                    connection: connection)
                return
            case "/api/v1/pwa/manual-claim":
                handleProtectedPreflight(
                    headers: headers,
                    allowedMethod: "POST",
                    allowedRequestHeaders: ["content-type"],
                    connection: connection)
                return
            case "/api/v1/events":
                handleProtectedPreflight(
                    headers: headers,
                    allowedMethod: "GET",
                    allowedRequestHeaders: [
                        "authorization",
                        "cache-control",
                    ],
                    connection: connection)
                return
            default:
                break
            }
        }

        if path == "/api/v1/pwa/manual-claim" {
            guard method == "POST" else {
                methodNotAllowed(
                    allow: "POST",
                    method: method,
                    connection: connection)
                return
            }
            handleManualPWAClaim(
                headers: headers,
                body: requestBody,
                hasQuery: components.query != nil,
                connection: connection)
            return
        }

        if path == "/api/v1/pwa/bootstrap" {
            guard method == "POST" else {
                methodNotAllowed(
                    allow: "POST",
                    method: method,
                    connection: connection)
                return
            }
            handlePWABootstrap(
                headers: headers,
                connection: connection)
            return
        }

        if path == "/api/v1/pwa/claim" {
            guard method == "POST" else {
                methodNotAllowed(
                    allow: "POST",
                    method: method,
                    connection: connection)
                return
            }
            handlePWAClaim(
                headers: headers,
                body: requestBody,
                hasQuery: components.query != nil,
                connection: connection)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            methodNotAllowed(
                allow: "GET, HEAD",
                method: method,
                connection: connection)
            return
        }

        if path == "/api/v1/events" {
            guard method == "GET" else {
                respond(
                    status: "405 Method Not Allowed",
                    contentType: "text/plain; charset=utf-8",
                    body: Data(),
                    to: connection,
                    sendsBody: false)
                return
            }
            guard normalizedRequestOrigin(headers: headers) != nil else {
                forbidden(connection)
                return
            }
            var corsHeaders: [String: String] = [:]
            if headers["origin"] != nil,
               !Self.isSameOriginPOST(headers: headers) {
                guard headers["cookie"] == nil,
                      let allowedHeaders = restrictedCORSHeaders(
                        headers: headers) else {
                    forbidden(connection)
                    return
                }
                corsHeaders = allowedHeaders
            }
            guard isAuthorized(headers: headers) else {
                unauthorized(
                    connection,
                    extraHeaders: corsHeaders,
                    resourcePolicy: corsHeaders.isEmpty
                        ? "same-origin"
                        : "cross-origin")
                return
            }
            if !serverInstanceID.isEmpty {
                corsHeaders["X-AI-Quota-Server-Instance"] =
                    serverInstanceID
                if corsHeaders["Access-Control-Allow-Origin"] != nil {
                    corsHeaders["Access-Control-Expose-Headers"] =
                        "X-AI-Quota-Server-Instance"
                }
            }
            beginEventStream(
                connection,
                extraHeaders: corsHeaders,
                resourcePolicy: corsHeaders[
                    "Access-Control-Allow-Origin"
                ] == nil ? "same-origin" : "cross-origin")
            return
        }

        if path == "/api/v1/health" {
            let corsHeaders: [String: String]
            if headers["origin"] != nil {
                guard let allowedHeaders = healthCORSHeaders(
                    headers: headers) else {
                    forbidden(connection)
                    return
                }
                corsHeaders = allowedHeaders
            } else {
                corsHeaders = [:]
            }
            let healthObject: [String: Any] = [
                "requiresPairingCode": requiresPairingCode,
                "status": "ok",
            ]
            let healthData = (try? JSONSerialization.data(
                withJSONObject: healthObject,
                options: [.sortedKeys]))
                ?? Data("{\"status\":\"ok\"}".utf8)
            respond(
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                body: healthData,
                extraHeaders: corsHeaders,
                resourcePolicy: corsHeaders.isEmpty
                    ? "same-origin"
                    : "cross-origin",
                to: connection,
                sendsBody: method != "HEAD")
            return
        }

        if path == "/manifest.webmanifest",
           let resource = staticResources[path] {
            respondWithManifest(
                resource,
                headers: headers,
                method: method,
                connection: connection)
            return
        }

        if path == "/",
           let resource = staticResources[path] {
            respondWithIndex(
                resource,
                method: method,
                connection: connection)
            return
        }

        guard let resource = staticResources[path] else {
            respond(
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not found.".utf8),
                to: connection,
                sendsBody: method != "HEAD")
            return
        }
        if resource.supportsByteRanges {
            respondWithByteRangeResource(
                resource,
                rangeHeader: headers["range"],
                method: method,
                connection: connection)
            return
        }
        respond(
            status: "200 OK",
            contentType: resource.contentType,
            body: resource.data,
            to: connection,
            sendsBody: method != "HEAD")
    }

    private func beginEventStream(
        _ connection: NWConnection,
        extraHeaders: [String: String] = [:],
        resourcePolicy: String = "same-origin"
    ) {
        guard eventConnections.count < maximumViewerCount else {
            respond(
                status: "429 Too Many Requests",
                contentType: "application/json; charset=utf-8",
                body: Data("{\"error\":\"viewer_limit_reached\"}".utf8),
                extraHeaders: ["Retry-After": "15"],
                to: connection)
            return
        }
        let identifier = ObjectIdentifier(connection)
        eventConnections[identifier] = connection
        var headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream; charset=utf-8",
            "Cache-Control: no-store, no-transform",
            "Connection: keep-alive",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "Cross-Origin-Resource-Policy: \(resourcePolicy)",
            "Permissions-Policy: \(Self.permissionsPolicy)",
        ]
        for (name, value) in extraHeaders.sorted(by: {
            $0.key < $1.key
        }) {
            headerLines.append("\(name): \(value)")
        }
        headerLines.append(contentsOf: [
            "",
            "retry: 3000",
            "",
            "",
        ])
        let headers = headerLines.joined(separator: "\r\n")
        send(Data(headers.utf8), to: connection)
        viewerCountHandler(eventConnections.count)
    }

    private func isAuthorized(headers: [String: String]) -> Bool {
        guard let authorization = headers["authorization"],
              authorization.hasPrefix("Bearer ") else {
            return false
        }
        let candidate = String(
            authorization.dropFirst("Bearer ".count))
        return Self.constantTimeEqual(
            candidate,
            pwaClaimBroker.accessToken)
    }

    private func unauthorized(
        _ connection: NWConnection,
        extraHeaders: [String: String] = [:],
        setCookies: [String] = [],
        resourcePolicy: String = "same-origin"
    ) {
        var headers = extraHeaders
        headers["WWW-Authenticate"] =
            "Bearer realm=\"AI Quota Bar\""
        respond(
            status: "401 Unauthorized",
            contentType: "application/json; charset=utf-8",
            body: Data("{\"error\":\"pairing_required\"}".utf8),
            extraHeaders: headers,
            setCookies: setCookies,
            resourcePolicy: resourcePolicy,
            to: connection)
    }

    private func methodNotAllowed(
        allow: String,
        method: String,
        connection: NWConnection
    ) {
        respond(
            status: "405 Method Not Allowed",
            contentType: "text/plain; charset=utf-8",
            body: Data("This dashboard is read-only.".utf8),
            extraHeaders: ["Allow": allow],
            to: connection,
            sendsBody: method != "HEAD")
    }

    private func handlePWABootstrap(
        headers: [String: String],
        connection: NWConnection
    ) {
        guard isAuthorized(headers: headers) else {
            unauthorized(connection)
            return
        }
        guard Self.isSameOriginPOST(headers: headers),
              let origin = normalizedRequestOrigin(headers: headers) else {
            forbidden(connection)
            return
        }

        let now = dateProvider()
        var nonce: String?
        for _ in 0..<4 {
            guard let candidate = Self.generatePWABootstrapNonce()
            else {
                break
            }
            if pwaClaimBroker.issue(
                nonce: candidate,
                now: now) {
                nonce = candidate
                break
            }
        }
        guard let nonce,
              let installID = Self.generatePWABootstrapNonce(),
              let installCredential =
                MobileDashboardPWAInstallCredential.issue(
                    accessToken: pwaClaimBroker.accessToken,
                    origin: origin,
                    issuedAt: now,
                    installID: installID) else {
            respond(
                status: "503 Service Unavailable",
                contentType: "application/json; charset=utf-8",
                body: Data(
                    "{\"error\":\"pairing_unavailable\"}".utf8),
                extraHeaders: ["Retry-After": "5"],
                to: connection)
            return
        }

        respond(
            status: "200 OK",
            contentType: "application/json; charset=utf-8",
            body: Data("{\"status\":\"ready\"}".utf8),
            setCookies: [
                Self.pwaBootstrapCookie(
                    nonce: nonce,
                    maxAge: pwaBootstrapMaxAge),
                Self.pwaInstallCookie(
                    credential: installCredential,
                    maxAge: pwaInstallMaxAge),
            ],
            to: connection)
    }

    private func handlePWAClaim(
        headers: [String: String],
        body: Data,
        hasQuery: Bool,
        connection: NWConnection
    ) {
        guard !hasQuery, body.isEmpty else {
            respond(
                status: "400 Bad Request",
                contentType: "application/json; charset=utf-8",
                body: Data("{\"error\":\"invalid_request\"}".utf8),
                to: connection)
            return
        }
        guard Self.isSameOriginPOST(headers: headers),
              normalizedRequestOrigin(headers: headers) != nil else {
            forbidden(connection)
            return
        }
        if !requiresPairingCode {
            guard !pwaClaimBroker.accessToken.isEmpty else {
                respond(
                    status: "503 Service Unavailable",
                    contentType: "application/json; charset=utf-8",
                    body: Data(
                        "{\"error\":\"pairing_unavailable\"}".utf8),
                    extraHeaders: ["Retry-After": "5"],
                    to: connection)
                return
            }
            respondWithAccessToken(
                pwaClaimBroker.accessToken,
                connection: connection)
            return
        }
        if let credential = Self.pwaInstallCredential(
            fromAuthorization: headers["authorization"])
        {
            handlePWAInstallClaim(
                credential: credential,
                headers: headers,
                connection: connection)
            return
        }
        let now = dateProvider()
        let clearBootstrapCookie = Self.pwaBootstrapCookie(
            nonce: "",
            maxAge: 0)
        let clearInstallCookie = Self.pwaInstallCookie(
            credential: "",
            maxAge: 0)
        if let installCredential = Self.cookieValue(
            named: Self.pwaInstallCookieName,
            in: headers["cookie"])
        {
            guard let origin = normalizedRequestOrigin(headers: headers),
                  MobileDashboardPWAInstallCredential.validate(
                    installCredential,
                    accessToken: pwaClaimBroker.accessToken,
                    origin: origin,
                    now: now,
                    lifetime: pwaInstallCredentialLifetime) else {
                unauthorized(
                    connection,
                    setCookies: [clearInstallCookie])
                return
            }
            respondWithAccessToken(
                pwaClaimBroker.accessToken,
                connection: connection)
            return
        }
        guard let nonce = Self.cookieValue(
            named: Self.pwaBootstrapCookieName,
            in: headers["cookie"]),
            Self.isValidPWABootstrapNonce(nonce),
            let token = pwaClaimBroker.claim(
                nonce: nonce,
                now: now)
        else {
            unauthorized(
                connection,
                setCookies: [
                    clearBootstrapCookie,
                    clearInstallCookie,
                ])
            return
        }

        respondWithAccessToken(
            token,
            setCookies: [clearBootstrapCookie],
            connection: connection)
    }

    private func handlePWAInstallClaim(
        credential: String,
        headers: [String: String],
        connection: NWConnection
    ) {
        guard let origin = normalizedRequestOrigin(headers: headers),
              MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: pwaClaimBroker.accessToken,
                origin: origin,
                now: dateProvider(),
                lifetime: pwaInstallCredentialLifetime)
        else {
            unauthorized(connection)
            return
        }
        respondWithAccessToken(
            pwaClaimBroker.accessToken,
            connection: connection)
    }

    private func normalizedRequestOrigin(
        headers: [String: String]
    ) -> String? {
        guard let hostHeader = headers["host"] else {
            return nil
        }
        return MobileDashboardRequestOrigin.normalized(
            hostHeader: hostHeader,
            expectedLocalHostName:
                MobileDashboardNetworkAddress.localHostName())
    }

    private func respondWithAccessToken(
        _ token: String,
        extraHeaders: [String: String] = [:],
        setCookies: [String] = [],
        connection: NWConnection
    ) {
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: ["token": token],
                options: [.sortedKeys])
        } catch {
            respond(
                status: "500 Internal Server Error",
                contentType: "application/json; charset=utf-8",
                body: Data(
                    "{\"error\":\"pairing_unavailable\"}".utf8),
                extraHeaders: extraHeaders,
                setCookies: setCookies,
                to: connection)
            return
        }
        respond(
            status: "200 OK",
            contentType: "application/json; charset=utf-8",
            body: body,
            extraHeaders: extraHeaders,
            setCookies: setCookies,
            to: connection)
    }

    private func respondWithManifest(
        _ resource: StaticResource,
        headers: [String: String],
        method: String,
        connection: NWConnection
    ) {
        var body = resource.data
        if let manifestObject = try? JSONSerialization.jsonObject(
                with: resource.data),
           var dynamicManifest = manifestObject as? [String: Any]
        {
            dynamicManifest["background_color"] =
                colorScheme.themeColorHex
            dynamicManifest["theme_color"] =
                colorScheme.themeColorHex
            let now = dateProvider()
            if let origin = normalizedRequestOrigin(headers: headers),
               let credential = manifestInstallCredential(
                    headers: headers,
                    origin: origin,
                    now: now) {
                dynamicManifest["start_url"] =
                    "/#install=\(credential)"
            }
            if let encoded = try? JSONSerialization.data(
                withJSONObject: dynamicManifest,
                options: [.sortedKeys]) {
                body = encoded
            }
        }

        respond(
            status: "200 OK",
            contentType: resource.contentType,
            body: body,
            to: connection,
            sendsBody: method != "HEAD")
    }

    private func respondWithIndex(
        _ resource: StaticResource,
        method: String,
        connection: NWConnection
    ) {
        var body = resource.data
        if var html = String(data: resource.data, encoding: .utf8) {
            html = html.replacingOccurrences(
                of: "data-color-scheme=\"auto\"",
                with:
                    "data-color-scheme=\"\(colorScheme.rawValue)\"")
            html = html.replacingOccurrences(
                of: "name=\"theme-color\" content=\"#000000\"",
                with:
                    "name=\"theme-color\" content=\"\(colorScheme.themeColorHex)\"")
            html = html.replacingOccurrences(
                of: "name=\"color-scheme\" content=\"light dark\"",
                with:
                    "name=\"color-scheme\" content=\"\(colorScheme.colorSchemeMetaContent)\"")
            html = html.replacingOccurrences(
                of:
                    "name=\"apple-mobile-web-app-status-bar-style\" content=\"black\"",
                with:
                    "name=\"apple-mobile-web-app-status-bar-style\" content=\"\(colorScheme.appleStatusBarStyle)\"")
            body = Data(html.utf8)
        }

        respond(
            status: "200 OK",
            contentType: resource.contentType,
            body: body,
            to: connection,
            sendsBody: method != "HEAD")
    }

    private func manifestInstallCredential(
        headers: [String: String],
        origin: String,
        now: Date
    ) -> String? {
        if let credential = Self.cookieValue(
            named: Self.pwaInstallCookieName,
            in: headers["cookie"]),
           MobileDashboardPWAInstallCredential.validate(
                credential,
                accessToken: pwaClaimBroker.accessToken,
                origin: origin,
                now: now,
                lifetime: pwaInstallCredentialLifetime) {
            return credential
        }
        guard let nonce = Self.cookieValue(
            named: Self.pwaBootstrapCookieName,
            in: headers["cookie"]),
              Self.isValidPWABootstrapNonce(nonce),
              pwaClaimBroker.contains(nonce: nonce, now: now),
              let installID = Self.generatePWABootstrapNonce() else {
            return nil
        }
        return MobileDashboardPWAInstallCredential.issue(
            accessToken: pwaClaimBroker.accessToken,
            origin: origin,
            issuedAt: now,
            installID: installID)
    }

    private func forbidden(_ connection: NWConnection) {
        respond(
            status: "403 Forbidden",
            contentType: "application/json; charset=utf-8",
            body: Data("{\"error\":\"invalid_origin\"}".utf8),
            to: connection)
    }

    private func handleManualPWAClaim(
        headers: [String: String],
        body: Data,
        hasQuery: Bool,
        connection: NWConnection
    ) {
        guard let corsHeaders = restrictedCORSHeaders(
            headers: headers) else {
            forbidden(connection)
            return
        }
        guard requiresPairingCode else {
            respondWithManualClaimError(
                status: "409 Conflict",
                error: "pairing_disabled",
                headers: corsHeaders,
                connection: connection)
            return
        }
        guard headers["cookie"] == nil,
              headers["authorization"] == nil else {
            respondWithManualClaimError(
                status: "403 Forbidden",
                error: "credentials_not_allowed",
                headers: corsHeaders,
                connection: connection)
            return
        }
        guard !hasQuery,
              !body.isEmpty,
              body.count <= Self.maximumManualClaimBodySize else {
            respondWithManualClaimError(
                status: "400 Bad Request",
                error: "invalid_request",
                headers: corsHeaders,
                connection: connection)
            return
        }
        guard headers["content-type"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "application/json" else {
            respondWithManualClaimError(
                status: "415 Unsupported Media Type",
                error: "unsupported_media_type",
                headers: corsHeaders,
                connection: connection)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(
                with: body),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["code"]),
              let code = dictionary["code"] as? String,
              code.utf8.count == Self.manualPairingCodeLength,
              code.utf8.allSatisfy({ (48...57).contains($0) }),
              let peerID = Self.peerIdentifier(connection.endpoint),
              let origin = headers["origin"] else {
            respondWithManualClaimError(
                status: "400 Bad Request",
                error: "invalid_request",
                headers: corsHeaders,
                connection: connection)
            return
        }
        guard !pwaClaimBroker.accessToken.isEmpty,
              !serverInstanceID.isEmpty else {
            respondWithManualClaimError(
                status: "503 Service Unavailable",
                error: "pairing_unavailable",
                headers: corsHeaders,
                retryAfter: 5,
                connection: connection)
            return
        }

        switch manualPairingBroker.claim(
            candidate: code,
            peerID: peerID,
            origin: origin,
            now: dateProvider()) {
        case .accepted:
            let responseObject = [
                "serverInstanceID": serverInstanceID,
                "token": pwaClaimBroker.accessToken,
            ]
            guard let responseBody = try? JSONSerialization.data(
                withJSONObject: responseObject,
                options: [.sortedKeys]) else {
                respondWithManualClaimError(
                    status: "503 Service Unavailable",
                    error: "pairing_unavailable",
                    headers: corsHeaders,
                    retryAfter: 5,
                    connection: connection)
                return
            }
            respond(
                status: "200 OK",
                contentType: "application/json; charset=utf-8",
                body: responseBody,
                extraHeaders: corsHeaders,
                resourcePolicy: "cross-origin",
                to: connection)
        case .invalid:
            respondWithManualClaimError(
                status: "401 Unauthorized",
                error: "invalid_pairing_code",
                headers: corsHeaders,
                connection: connection)
        case let .rateLimited(retryAfter):
            respondWithManualClaimError(
                status: "429 Too Many Requests",
                error: "pairing_rate_limited",
                headers: corsHeaders,
                retryAfter: retryAfter,
                connection: connection)
        case .unavailable:
            respondWithManualClaimError(
                status: "503 Service Unavailable",
                error: "pairing_unavailable",
                headers: corsHeaders,
                retryAfter: 5,
                connection: connection)
        }
    }

    private func respondWithManualClaimError(
        status: String,
        error: String,
        headers: [String: String],
        retryAfter: Int? = nil,
        connection: NWConnection
    ) {
        var responseHeaders = headers
        if let retryAfter {
            responseHeaders["Retry-After"] = String(max(1, retryAfter))
        }
        let body = (try? JSONSerialization.data(
            withJSONObject: ["error": error],
            options: [.sortedKeys]))
            ?? Data("{\"error\":\"pairing_unavailable\"}".utf8)
        respond(
            status: status,
            contentType: "application/json; charset=utf-8",
            body: body,
            extraHeaders: responseHeaders,
            resourcePolicy: "cross-origin",
            to: connection)
    }

    private func handleProtectedPreflight(
        headers: [String: String],
        allowedMethod: String,
        allowedRequestHeaders: Set<String>,
        connection: NWConnection
    ) {
        let requestedHeaders = Self.requestedCORSHeaders(
            headers["access-control-request-headers"])
        let requiredHeaders: Set<String> = allowedMethod == "POST"
            ? ["content-type"]
            : ["authorization"]
        guard headers["cookie"] == nil,
              headers["authorization"] == nil,
              headers["access-control-request-method"]?
                .uppercased() == allowedMethod,
              let requestedHeaders,
              requiredHeaders.isSubset(of: requestedHeaders),
              requestedHeaders.isSubset(of: allowedRequestHeaders),
              let corsHeaders = restrictedCORSHeaders(
                headers: headers) else {
            forbidden(connection)
            return
        }
        if let privateNetwork = headers[
            "access-control-request-private-network"
        ], privateNetwork.lowercased() != "true" {
            forbidden(connection)
            return
        }

        var responseHeaders = corsHeaders
        responseHeaders["Access-Control-Allow-Methods"] = allowedMethod
        responseHeaders["Access-Control-Allow-Headers"] =
            allowedRequestHeaders.sorted().map {
                switch $0 {
                case "authorization": return "Authorization"
                case "cache-control": return "Cache-Control"
                case "content-type": return "Content-Type"
                default: return $0
                }
            }.joined(separator: ", ")
        responseHeaders["Access-Control-Max-Age"] = "60"
        if headers["access-control-request-private-network"]?
            .lowercased() == "true" {
            responseHeaders["Access-Control-Allow-Private-Network"] =
                "true"
        }
        respond(
            status: "204 No Content",
            contentType: "text/plain; charset=utf-8",
            body: Data(),
            extraHeaders: responseHeaders,
            resourcePolicy: "cross-origin",
            to: connection,
            sendsBody: false)
    }

    private func handleHealthPreflight(
        headers: [String: String],
        connection: NWConnection
    ) {
        let requestedHeaders = headers[
            "access-control-request-headers"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard headers["access-control-request-method"]?
                .uppercased() == "GET",
              requestedHeaders.isEmpty,
              let corsHeaders = healthCORSHeaders(
                headers: headers) else {
            forbidden(connection)
            return
        }
        var responseHeaders = corsHeaders
        responseHeaders["Access-Control-Allow-Methods"] = "GET"
        responseHeaders["Access-Control-Max-Age"] = "60"
        if headers["access-control-request-private-network"]?
            .lowercased() == "true" {
            responseHeaders["Access-Control-Allow-Private-Network"] =
                "true"
        }
        respond(
            status: "204 No Content",
            contentType: "text/plain; charset=utf-8",
            body: Data(),
            extraHeaders: responseHeaders,
            resourcePolicy: "cross-origin",
            to: connection,
            sendsBody: false)
    }

    private func restrictedCORSHeaders(
        headers: [String: String]
    ) -> [String: String]? {
        guard let requestOrigin = normalizedRequestOrigin(
                headers: headers),
              let requestComponents = URLComponents(
                string: requestOrigin),
              let rawOrigin = headers["origin"],
              let origin = Self.normalizedCurrentAccessOrigin(
                rawOrigin,
                requiredPort: requestComponents.port ?? 80,
                allowedHosts: sensitiveCORSHostProvider()),
              origin.caseInsensitiveCompare(rawOrigin) == .orderedSame else {
            return nil
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Vary": "Origin, Access-Control-Request-Private-Network",
        ]
    }

    private func healthCORSHeaders(
        headers: [String: String]
    ) -> [String: String]? {
        guard normalizedRequestOrigin(headers: headers) != nil,
              let rawOrigin = headers["origin"],
              let origin = MobileDashboardCandidateAddress
                .normalizedOrigin(rawOrigin, defaultPort: 80),
              origin.caseInsensitiveCompare(rawOrigin) == .orderedSame else {
            return nil
        }
        return [
            "Access-Control-Allow-Origin": origin,
            "Vary": "Origin, Access-Control-Request-Private-Network",
        ]
    }

    static func normalizedCurrentAccessOrigin(
        _ rawOrigin: String,
        requiredPort: Int? = nil,
        allowedHosts: Set<String>? = nil
    ) -> String? {
        guard rawOrigin == rawOrigin.trimmingCharacters(
                in: .whitespacesAndNewlines),
              rawOrigin.utf8.count <= 255,
              let components = URLComponents(string: rawOrigin),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              var host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        let allowedHosts = allowedHosts ?? currentAccessHosts()
        guard allowedHosts.contains(host) else {
            return nil
        }
        let port = components.port ?? 80
        guard (1...65_535).contains(port),
              requiredPort == nil || requiredPort == port else {
            return nil
        }
        var normalized = URLComponents()
        normalized.scheme = "http"
        normalized.host = host
        if port != 80 {
            normalized.port = port
        }
        return normalized.string
    }

    static func currentAccessHosts() -> Set<String> {
        var hosts = Set(
            MobileDashboardNetworkAddress.localIPv4Addresses())
        if let localHostName = MobileDashboardNetworkAddress
            .localHostName() {
            hosts.insert("\(localHostName).local")
        }
        return hosts
    }

    private func respondWithByteRangeResource(
        _ resource: StaticResource,
        rangeHeader: String?,
        method: String,
        connection: NWConnection
    ) {
        let commonHeaders = ["Accept-Ranges": "bytes"]
        guard let rangeHeader else {
            respond(
                status: "200 OK",
                contentType: resource.contentType,
                body: resource.data,
                extraHeaders: commonHeaders,
                cacheControl: "no-cache",
                to: connection,
                sendsBody: method != "HEAD")
            return
        }

        guard let range = Self.byteRange(
            from: rangeHeader,
            resourceLength: resource.data.count)
        else {
            var headers = commonHeaders
            headers["Content-Range"] =
                "bytes */\(resource.data.count)"
            respond(
                status: "416 Range Not Satisfiable",
                contentType: "text/plain; charset=utf-8",
                body: Data("Requested range is not satisfiable.".utf8),
                extraHeaders: headers,
                cacheControl: "no-cache",
                to: connection,
                sendsBody: method != "HEAD")
            return
        }

        var headers = commonHeaders
        headers["Content-Range"] =
            "bytes \(range.lowerBound)-\(range.upperBound - 1)"
                + "/\(resource.data.count)"
        respond(
            status: "206 Partial Content",
            contentType: resource.contentType,
            body: resource.data.subdata(in: range),
            extraHeaders: headers,
            cacheControl: "no-cache",
            to: connection,
            sendsBody: method != "HEAD")
    }

    private func respond(
        status: String,
        contentType: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        setCookies: [String] = [],
        cacheControl: String = "no-store",
        resourcePolicy: String = "same-origin",
        to connection: NWConnection,
        sendsBody: Bool = true
    ) {
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: \(cacheControl)",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "X-Frame-Options: DENY",
            "Cross-Origin-Resource-Policy: \(resourcePolicy)",
            "Permissions-Policy: \(Self.permissionsPolicy)",
            "Content-Security-Policy: \(Self.contentSecurityPolicy)",
        ]
        for (name, value) in extraHeaders.sorted(by: {
            $0.key < $1.key
        }) {
            headerLines.append("\(name): \(value)")
        }
        for cookie in setCookies {
            headerLines.append("Set-Cookie: \(cookie)")
        }
        headerLines.append("")
        headerLines.append("")

        var responseData = Data(
            headerLines.joined(separator: "\r\n").utf8)
        if sendsBody {
            responseData.append(body)
        }
        connection.send(
            content: responseData,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private func send(_ data: Data, to connection: NWConnection) {
        connection.send(
            content: data,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, error != nil else {
                    return
                }
                self.queue.async {
                    connection.cancel()
                    self.removeConnection(connection)
                }
            })
    }

    private func sendEvent(
        _ data: Data,
        to connection: NWConnection
    ) {
        let identifier = ObjectIdentifier(connection)
        guard eventConnections[identifier] != nil else { return }
        guard !eventSendsInFlight.contains(identifier) else {
            latestQueuedEvent[identifier] = data
            return
        }

        eventSendsInFlight.insert(identifier)
        connection.send(
            content: data,
            completion: .contentProcessed {
                [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.queue.async {
                    self.eventSendsInFlight.remove(identifier)
                    if error != nil {
                        connection.cancel()
                        self.removeConnection(connection)
                        return
                    }
                    guard let next = self.latestQueuedEvent
                        .removeValue(forKey: identifier) else {
                        return
                    }
                    self.sendEvent(next, to: connection)
                }
            })
    }

    private func cancelRequestTimeout(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        requestTimeouts.removeValue(forKey: identifier)?.cancel()
    }

    private func removeConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        requestTimeouts.removeValue(forKey: identifier)?.cancel()
        connections.removeValue(forKey: identifier)
        eventSendsInFlight.remove(identifier)
        latestQueuedEvent.removeValue(forKey: identifier)
        if eventConnections.removeValue(forKey: identifier) != nil {
            viewerCountHandler(eventConnections.count)
        }
    }

    static func isAllowedLocalEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        return MobileDashboardNetworkAddress.isLocalOrLoopbackHost(
            String(describing: host))
    }

    static func peerIdentifier(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else {
            return nil
        }
        let value = String(describing: host).lowercased()
        guard isAllowedLocalEndpoint(endpoint),
              !value.isEmpty,
              value.utf8.count <= 128 else {
            return nil
        }
        return value
    }

    static func requestedCORSHeaders(
        _ rawValue: String?
    ) -> Set<String>? {
        guard let rawValue,
              !rawValue.isEmpty,
              rawValue.utf8.count <= 512 else {
            return nil
        }
        var result = Set<String>()
        for field in rawValue.split(
            separator: ",",
            omittingEmptySubsequences: false
        ) {
            let value = field.trimmingCharacters(
                in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ byte in
                      (65...90).contains(byte)
                          || (97...122).contains(byte)
                          || (48...57).contains(byte)
                          || byte == 45
                  }) else {
                return nil
            }
            result.insert(value)
        }
        return result
    }

    static func parseHeaders(
        _ lines: [String]
    ) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                if [
                    "access-control-request-headers",
                    "access-control-request-method",
                    "access-control-request-private-network",
                    "authorization",
                    "content-length",
                    "content-type",
                    "host",
                    "origin",
                    "range",
                    "transfer-encoding",
                ]
                    .contains(name),
                   headers[name] != nil {
                    // Ambiguous security-sensitive or Range headers must
                    // not fall back to last-header-wins behavior.
                    headers[name] = ""
                } else if name == "cookie",
                          let existing = headers[name] {
                    headers[name] = "\(existing); \(value)"
                } else {
                    headers[name] = value
                }
            }
        }
        return headers
    }

    static func byteRange(
        from headerValue: String,
        resourceLength: Int
    ) -> Range<Int>? {
        guard resourceLength > 0,
              !headerValue.contains(","),
              headerValue.prefix("bytes=".count).lowercased()
                == "bytes=" else {
            return nil
        }

        let value = headerValue.dropFirst("bytes=".count)
        guard !value.isEmpty,
              value.allSatisfy({ $0 == "-" || $0.isNumber }),
              value.filter({ $0 == "-" }).count == 1,
              let separator = value.firstIndex(of: "-") else {
            return nil
        }
        let startText = value[..<separator]
        let endText = value[value.index(after: separator)...]

        if startText.isEmpty {
            guard let suffixLength = strictNonnegativeInt(endText),
                  suffixLength > 0 else {
                return nil
            }
            let boundedLength = min(suffixLength, resourceLength)
            return (resourceLength - boundedLength)..<resourceLength
        }

        guard let start = strictNonnegativeInt(startText),
              start < resourceLength else {
            return nil
        }
        if endText.isEmpty {
            return start..<resourceLength
        }
        guard let requestedEnd = strictNonnegativeInt(endText),
              requestedEnd >= start else {
            return nil
        }
        let end = min(requestedEnd, resourceLength - 1)
        return start..<(end + 1)
    }

    private static func strictNonnegativeInt(
        _ text: Substring
    ) -> Int? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int(text)
    }

    static func isSameOriginPOST(
        headers: [String: String]
    ) -> Bool {
        guard let origin = headers["origin"],
              let hostHeader = headers["host"],
              let originComponents = URLComponents(
                string: origin),
              originComponents.scheme?.lowercased() == "http",
              originComponents.user == nil,
              originComponents.password == nil,
              originComponents.path.isEmpty,
              originComponents.query == nil,
              originComponents.fragment == nil,
              let originHost = originComponents.host?
                .lowercased(),
              let hostComponents = URLComponents(
                string: "http://\(hostHeader)"),
              hostComponents.user == nil,
              hostComponents.password == nil,
              hostComponents.path.isEmpty,
              hostComponents.query == nil,
              hostComponents.fragment == nil,
              let requestHost = hostComponents.host?
                .lowercased(),
              originHost == requestHost
        else {
            return false
        }
        let originPort = originComponents.port ?? 80
        let requestPort = hostComponents.port ?? 80
        return originPort == requestPort
    }

    static func constantTimeEqual(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let maximumCount = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count
        for index in 0..<maximumCount {
            let lhsByte = index < lhsBytes.count
                ? lhsBytes[index]
                : 0
            let rhsByte = index < rhsBytes.count
                ? rhsBytes[index]
                : 0
            difference |= Int(lhsByte ^ rhsByte)
        }
        return difference == 0
    }

    static func cookieValue(
        named expectedName: String,
        in header: String?
    ) -> String? {
        guard let header,
              header.utf8.count <= 8_192 else {
            return nil
        }
        var result: String?
        for field in header.split(
            separator: ";",
            omittingEmptySubsequences: false
        ) {
            guard let separator = field.firstIndex(of: "=") else {
                continue
            }
            let name = field[..<separator]
                .trimmingCharacters(in: .whitespaces)
            guard name == expectedName else { continue }
            guard result == nil else {
                // Reject duplicate security cookie names rather than
                // depending on intermediary-specific precedence.
                return nil
            }
            let value = field[field.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.utf8.count <= 256 else {
                return nil
            }
            result = value
        }
        return result
    }

    static func pwaInstallCredential(
        fromAuthorization authorization: String?
    ) -> String? {
        let prefix = "\(pwaInstallAuthorizationScheme) "
        guard let authorization,
              authorization.hasPrefix(prefix) else {
            return nil
        }
        let credential = String(
            authorization.dropFirst(prefix.count))
        guard !credential.isEmpty,
              credential.utf8.count <= 256,
              !credential.contains(where: \.isWhitespace) else {
            return nil
        }
        return credential
    }

    static func isValidPWABootstrapNonce(
        _ nonce: String
    ) -> Bool {
        nonce.utf8.count == 43
            && nonce.utf8.allSatisfy {
                (65...90).contains($0)
                    || (97...122).contains($0)
                    || (48...57).contains($0)
                    || $0 == 45
                    || $0 == 95
            }
    }

    static func generatePWABootstrapNonce() -> String? {
        generateRandomBase64URL(byteCount: 32)
    }

    static func generateRandomBase64URL(
        byteCount: Int
    ) -> String? {
        guard byteCount > 0,
              byteCount <= 128 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pwaBootstrapCookie(
        nonce: String,
        maxAge: Int
    ) -> String {
        "\(pwaBootstrapCookieName)=\(nonce); "
            + "HttpOnly; SameSite=Strict; Path=/; "
            + "Max-Age=\(max(0, maxAge))"
    }

    private static func pwaInstallCookie(
        credential: String,
        maxAge: Int
    ) -> String {
        "\(pwaInstallCookieName)=\(credential); "
            + "HttpOnly; SameSite=Strict; Path=/; "
            + "Max-Age=\(max(0, maxAge))"
    }

    private static func loadStaticResources()
        throws -> [String: StaticResource] {
        let specifications: [
            (path: String, name: String, extension: String, type: String)
        ] = [
            ("/", "index", "html", "text/html; charset=utf-8"),
            ("/app.css", "app", "css", "text/css; charset=utf-8"),
            ("/app.js", "app", "js", "text/javascript; charset=utf-8"),
            (
                "/manifest.webmanifest",
                "manifest",
                "webmanifest",
                "application/manifest+json; charset=utf-8"
            ),
            (
                "/icon-192.png",
                "icon-192",
                "png",
                "image/png"
            ),
            (
                "/icon-512.png",
                "icon-512",
                "png",
                "image/png"
            ),
            (
                "/icon-maskable-512.png",
                "icon-maskable-512",
                "png",
                "image/png"
            ),
            (
                "/apple-touch-icon.png",
                "apple-touch-icon",
                "png",
                "image/png"
            ),
            (
                "/wake-ambient.mp4",
                "wake-ambient",
                "mp4",
                "video/mp4"
            ),
        ]

        return try Dictionary(
            uniqueKeysWithValues: specifications.map { specification in
                guard let url = staticResourceURL(
                    name: specification.name,
                    extension: specification.extension) else {
                    throw MobileDashboardServerError.missingResource(
                        "\(specification.name).\(specification.extension)")
                }
                return (
                    specification.path,
                    StaticResource(
                        data: try Data(contentsOf: url),
                        contentType: specification.type,
                        supportsByteRanges:
                            specification.path == "/wake-ambient.mp4")
                )
            })
    }

    static func staticResourceURL(
        name: String,
        extension: String
    ) -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: "MobileDashboard")
            ?? Bundle.module.url(
                forResource: name,
                withExtension: `extension`)
    }
}

struct MobileDashboardPWAClaimBroker {
    private struct Entry {
        let expiresAt: Date
        let sequence: UInt64
    }

    private let lifetime: TimeInterval
    private let maximumOutstanding: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private(set) var accessToken = ""

    init(
        lifetime: TimeInterval,
        maximumOutstanding: Int
    ) {
        self.lifetime = max(1, lifetime)
        self.maximumOutstanding = max(
            1,
            maximumOutstanding)
    }

    var outstandingCount: Int {
        entries.count
    }

    mutating func reset(accessToken: String) {
        entries.removeAll(keepingCapacity: false)
        sequence = 0
        self.accessToken = accessToken
    }

    mutating func issue(
        nonce: String,
        now: Date
    ) -> Bool {
        pruneExpired(now: now)
        guard !accessToken.isEmpty,
              entries[nonce] == nil else {
            return false
        }
        if entries.count >= maximumOutstanding,
           let oldest = entries.min(by: {
               if $0.value.expiresAt != $1.value.expiresAt {
                   return $0.value.expiresAt
                       < $1.value.expiresAt
               }
               return $0.value.sequence
                   < $1.value.sequence
           })?.key {
            entries.removeValue(forKey: oldest)
        }
        sequence &+= 1
        entries[nonce] = Entry(
            expiresAt: now.addingTimeInterval(lifetime),
            sequence: sequence)
        return true
    }

    mutating func claim(
        nonce: String,
        now: Date
    ) -> String? {
        pruneExpired(now: now)
        guard entries.removeValue(forKey: nonce) != nil,
              !accessToken.isEmpty else {
            return nil
        }
        return accessToken
    }

    mutating func contains(nonce: String, now: Date) -> Bool {
        pruneExpired(now: now)
        return entries[nonce] != nil && !accessToken.isEmpty
    }

    private mutating func pruneExpired(now: Date) {
        entries = entries.filter {
            $0.value.expiresAt > now
        }
    }
}

enum MobileDashboardManualPairingClaimResult: Equatable {
    case accepted
    case invalid
    case rateLimited(retryAfter: Int)
    case unavailable
}

struct MobileDashboardManualPairingBroker {
    private struct FailureWindow {
        var startedAt: Date
        var count: Int
    }

    static let maximumFailedAttempts = 5
    static let maximumGlobalFailedAttempts = 20
    static let failureWindowLifetime: TimeInterval = 5 * 60
    static let maximumSuccessfulClaims = 3
    static let maximumTrackedFailureKeys = 64

    private var code: String?
    private var expiresAt: Date?
    private var lockedClientID: String?
    private var successfulClaimCount = 0
    private var peerFailures: [String: FailureWindow] = [:]
    private var clientFailures: [String: FailureWindow] = [:]
    private var globalFailures: FailureWindow?

    var trackedFailureKeyCount: Int {
        peerFailures.count + clientFailures.count
    }

    mutating func reset(
        code: String?,
        expiresAt: Date?
    ) {
        if let code,
           code.utf8.count
            == MobileDashboardHTTPServer.manualPairingCodeLength,
           code.utf8.allSatisfy({ (48...57).contains($0) }) {
            self.code = code
            self.expiresAt = expiresAt
        } else {
            self.code = nil
            self.expiresAt = nil
        }
        lockedClientID = nil
        successfulClaimCount = 0
        peerFailures.removeAll(keepingCapacity: false)
        clientFailures.removeAll(keepingCapacity: false)
        globalFailures = nil
    }

    mutating func claim(
        candidate: String,
        peerID: String,
        origin: String,
        now: Date
    ) -> MobileDashboardManualPairingClaimResult {
        pruneFailures(now: now)
        let clientID = "\(peerID)\n\(origin)"
        if isGlobalRateLimited(now: now)
            || isRateLimited(peerID, in: peerFailures, now: now)
            || isRateLimited(clientID, in: clientFailures, now: now) {
            return .rateLimited(
                retryAfter: retryAfter(
                    peerID: peerID,
                    clientID: clientID,
                    now: now))
        }

        // Always perform a fixed-work comparison, including unavailable and
        // expired states, so the response path does not disclose the code.
        let expectedCode = code
            ?? String(repeating: "\u{0}", count: 8)
        let codeMatches = MobileDashboardHTTPServer.constantTimeEqual(
            candidate,
            expectedCode)
        guard code != nil, let expiresAt else {
            return .unavailable
        }
        guard expiresAt > now else {
            registerFailure(
                peerID: peerID,
                clientID: clientID,
                now: now)
            return failureResult(
                peerID: peerID,
                clientID: clientID,
                now: now)
        }
        guard codeMatches else {
            registerFailure(
                peerID: peerID,
                clientID: clientID,
                now: now)
            return failureResult(
                peerID: peerID,
                clientID: clientID,
                now: now)
        }

        if let lockedClientID,
           lockedClientID != clientID {
            registerFailure(
                peerID: peerID,
                clientID: clientID,
                now: now)
            return failureResult(
                peerID: peerID,
                clientID: clientID,
                now: now)
        }
        guard successfulClaimCount
            < Self.maximumSuccessfulClaims else {
            return .rateLimited(
                retryAfter: max(
                    1,
                    Int(expiresAt.timeIntervalSince(now).rounded(.up))))
        }

        self.lockedClientID = clientID
        successfulClaimCount += 1
        peerFailures.removeValue(forKey: peerID)
        clientFailures.removeValue(forKey: clientID)
        return .accepted
    }

    private mutating func registerFailure(
        peerID: String,
        clientID: String,
        now: Date
    ) {
        Self.incrementFailure(
            key: peerID,
            in: &peerFailures,
            now: now)
        Self.incrementFailure(
            key: clientID,
            in: &clientFailures,
            now: now)
        if var window = globalFailures,
           now.timeIntervalSince(window.startedAt)
            < Self.failureWindowLifetime {
            window.count += 1
            globalFailures = window
        } else {
            globalFailures = FailureWindow(
                startedAt: now,
                count: 1)
        }
    }

    private func failureResult(
        peerID: String,
        clientID: String,
        now: Date
    ) -> MobileDashboardManualPairingClaimResult {
        if isGlobalRateLimited(now: now)
            || isRateLimited(peerID, in: peerFailures, now: now)
            || isRateLimited(clientID, in: clientFailures, now: now) {
            return .rateLimited(
                retryAfter: retryAfter(
                    peerID: peerID,
                    clientID: clientID,
                    now: now))
        }
        return .invalid
    }

    private func isRateLimited(
        _ key: String,
        in failures: [String: FailureWindow],
        now: Date
    ) -> Bool {
        guard let window = failures[key] else { return false }
        return window.count >= Self.maximumFailedAttempts
            && now.timeIntervalSince(window.startedAt)
                < Self.failureWindowLifetime
    }

    private func isGlobalRateLimited(now: Date) -> Bool {
        guard let window = globalFailures else { return false }
        return window.count >= Self.maximumGlobalFailedAttempts
            && now.timeIntervalSince(window.startedAt)
                < Self.failureWindowLifetime
    }

    private func retryAfter(
        peerID: String,
        clientID: String,
        now: Date
    ) -> Int {
        let starts = [
            peerFailures[peerID]?.startedAt,
            clientFailures[clientID]?.startedAt,
            globalFailures?.startedAt,
        ].compactMap { $0 }
        guard let oldest = starts.min() else { return 1 }
        return max(
            1,
            Int((Self.failureWindowLifetime
                - now.timeIntervalSince(oldest)).rounded(.up)))
    }

    private static func incrementFailure(
        key: String,
        in failures: inout [String: FailureWindow],
        now: Date
    ) {
        if var window = failures[key],
           now.timeIntervalSince(window.startedAt)
            < Self.failureWindowLifetime {
            window.count += 1
            failures[key] = window
        } else {
            failures[key] = FailureWindow(
                startedAt: now,
                count: 1)
        }
        while failures.count > Self.maximumTrackedFailureKeys,
              let oldestKey = failures.min(by: {
                  $0.value.startedAt < $1.value.startedAt
              })?.key {
            failures.removeValue(forKey: oldestKey)
        }
    }

    private mutating func pruneFailures(now: Date) {
        peerFailures = peerFailures.filter {
            now.timeIntervalSince($0.value.startedAt)
                < Self.failureWindowLifetime
        }
        clientFailures = clientFailures.filter {
            now.timeIntervalSince($0.value.startedAt)
                < Self.failureWindowLifetime
        }
        if let globalFailures,
           now.timeIntervalSince(globalFailures.startedAt)
            >= Self.failureWindowLifetime {
            self.globalFailures = nil
        }
    }
}

enum MobileDashboardPWAInstallCredential {
    static let version = "v1"
    static let maximumClockSkew: TimeInterval = 5 * 60

    static func issue(
        accessToken: String,
        origin: String,
        issuedAt: Date,
        installID: String
    ) -> String? {
        guard !accessToken.isEmpty,
              isValidOrigin(origin),
              MobileDashboardHTTPServer
                .isValidPWABootstrapNonce(installID) else {
            return nil
        }
        let seconds = issuedAt.timeIntervalSince1970.rounded(.down)
        guard seconds >= 0,
              seconds <= Double(Int64.max) else {
            return nil
        }
        let issuedAtValue = Int64(seconds)
        let payload = signedPayload(
            issuedAt: issuedAtValue,
            origin: origin,
            installID: installID)
        let key = SymmetricKey(data: Data(accessToken.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: key)
        return [
            version,
            String(issuedAtValue),
            installID,
            base64URL(Data(signature)),
        ].joined(separator: ".")
    }

    static func validate(
        _ credential: String,
        accessToken: String,
        origin: String,
        now: Date,
        lifetime: TimeInterval
    ) -> Bool {
        guard !accessToken.isEmpty,
              lifetime > 0,
              credential.utf8.count <= 256,
              isValidOrigin(origin) else {
            return false
        }
        let parts = credential.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == Substring(version),
              parts[1].utf8.count <= 19,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let issuedAt = Int64(parts[1]),
              issuedAt >= 0 else {
            return false
        }
        let installID = String(parts[2])
        let suppliedSignature = String(parts[3])
        guard MobileDashboardHTTPServer
                .isValidPWABootstrapNonce(installID),
              MobileDashboardHTTPServer
                .isValidPWABootstrapNonce(suppliedSignature) else {
            return false
        }

        let nowSeconds = now.timeIntervalSince1970
        let issuedAtSeconds = TimeInterval(issuedAt)
        guard issuedAtSeconds <= nowSeconds + maximumClockSkew,
              nowSeconds < issuedAtSeconds + lifetime else {
            return false
        }

        let payload = signedPayload(
            issuedAt: issuedAt,
            origin: origin,
            installID: installID)
        let key = SymmetricKey(data: Data(accessToken.utf8))
        let expectedSignature = base64URL(
            Data(
                HMAC<SHA256>.authenticationCode(
                    for: Data(payload.utf8),
                    using: key)))
        return MobileDashboardHTTPServer.constantTimeEqual(
            suppliedSignature,
            expectedSignature)
    }

    private static func signedPayload(
        issuedAt: Int64,
        origin: String,
        installID: String
    ) -> String {
        [
            "AIQuotaBar.PWAInstall",
            version,
            String(issuedAt),
            origin,
            installID,
        ].joined(separator: "\n")
    }

    private static func isValidOrigin(_ origin: String) -> Bool {
        guard origin.utf8.count <= 512,
              let components = URLComponents(string: origin),
              components.scheme == "http",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Produces the sole origin spelling used by install credentials. Restricting
/// the request Host here prevents a LAN client from minting a credential for
/// an attacker-controlled or public hostname through Host-header spoofing.
enum MobileDashboardRequestOrigin {
    static func normalized(
        hostHeader: String,
        expectedLocalHostName: String?
    ) -> String? {
        guard !hostHeader.isEmpty,
              hostHeader.utf8.count <= 255,
              !hostHeader.hasSuffix(":"),
              !hostHeader.contains(where: {
                  "@/#?\\".contains($0)
              }),
              !hostHeader.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }),
              let components = URLComponents(
                string: "http://\(hostHeader)"),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              var host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        if let port = components.port,
           !(1...65_535).contains(port) {
            return nil
        }

        if host.hasSuffix(".") {
            host.removeLast()
        }
        let isAllowedAddress = MobileDashboardNetworkAddress
            .isLocalOrLoopbackHost(host)
        let isExpectedBonjourName: Bool
        if host.hasSuffix(".local") {
            let label = String(host.dropLast(".local".count))
            isExpectedBonjourName =
                MobileDashboardNetworkAddress
                    .normalizedLocalHostName(label)
                    == MobileDashboardNetworkAddress
                    .normalizedLocalHostName(expectedLocalHostName)
                && expectedLocalHostName != nil
        } else {
            isExpectedBonjourName = false
        }
        guard isAllowedAddress || isExpectedBonjourName else {
            return nil
        }

        var normalizedComponents = URLComponents()
        normalizedComponents.scheme = "http"
        normalizedComponents.host = host
        if let port = components.port, port != 80 {
            normalizedComponents.port = port
        }
        guard let origin = normalizedComponents.string,
              !origin.isEmpty else {
            return nil
        }
        return origin
    }
}

/// Canonicalizes user-supplied fallback addresses without ever accepting a
/// public host or URL components that could smuggle credentials or a target
/// path. The resulting value is a base origin only; candidate lists remain a
/// client-side concern.
enum MobileDashboardCandidateAddress {
    static let defaultPort = 18_765

    static func normalizedOrigin(
        _ rawValue: String,
        defaultPort: Int = MobileDashboardCandidateAddress.defaultPort
    ) -> String? {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 255,
              (1...65_535).contains(defaultPort),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }

        let hasScheme = value.range(
            of: "://") != nil
        let candidate = hasScheme ? value : "http://\(value)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              var host = components.host?.lowercased(),
              !host.isEmpty,
              !host.contains(":"),
              !host.contains("%") else {
            return nil
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        let isAllowedIPv4 = MobileDashboardNetworkAddress
            .isPrivateOrLinkLocalIPv4(host)
        let isAllowedBonjour: Bool
        if host.hasSuffix(".local") {
            let label = String(host.dropLast(".local".count))
            isAllowedBonjour = !label.contains(".")
                && MobileDashboardNetworkAddress
                    .normalizedLocalHostName(label) == label
        } else {
            isAllowedBonjour = false
        }
        guard isAllowedIPv4 || isAllowedBonjour else {
            return nil
        }

        let port = components.port ?? defaultPort
        guard (1...65_535).contains(port) else { return nil }
        var normalized = URLComponents()
        normalized.scheme = "http"
        normalized.host = host
        if port != 80 {
            normalized.port = port
        }
        return normalized.string
    }
}

private struct StaticResource {
    let data: Data
    let contentType: String
    let supportsByteRanges: Bool
}

private enum MobileDashboardServerError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name):
            return "The mobile dashboard resource \(name) is missing."
        }
    }
}

enum MobileDashboardNetworkAddress {
    static func localHostName() -> String? {
        guard let rawName = SCDynamicStoreCopyLocalHostName(nil)
        else {
            return nil
        }
        return normalizedLocalHostName(rawName as String)
    }

    static func normalizedLocalHostName(_ rawName: String?) -> String? {
        guard var name = rawName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !name.isEmpty else {
            return nil
        }

        if name.hasSuffix(".") {
            name.removeLast()
        }
        if name.hasSuffix(".local") {
            name.removeLast(".local".count)
        }

        guard !name.isEmpty,
              name.utf8.count <= 63,
              !name.hasPrefix("-"),
              !name.hasSuffix("-"),
              name.utf8.allSatisfy({ byte in
                  (byte >= Character("a").asciiValue!
                      && byte <= Character("z").asciiValue!)
                      || (byte >= Character("0").asciiValue!
                          && byte <= Character("9").asciiValue!)
                      || byte == Character("-").asciiValue!
              }) else {
            return nil
        }
        return name
    }

    static func localIPv4Addresses() -> [String] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0,
              let firstInterface = interfacePointer else {
            return []
        }
        defer { freeifaddrs(interfacePointer) }

        var candidates: [(priority: Int, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }

            var address = addressPointer.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(address.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST)
            guard result == 0 else { continue }
            let value = String(cString: host)
            guard isPrivateOrLinkLocalIPv4(value) else { continue }

            let interfaceName = String(cString: interface.ifa_name)
            let priority: Int
            if interfaceName == "en0" {
                priority = 0
            } else if interfaceName.hasPrefix("en") {
                priority = 1
            } else if interfaceName.hasPrefix("bridge") {
                priority = 2
            } else {
                priority = 3
            }
            candidates.append((priority, value))
        }

        return candidates
            .sorted {
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                return $0.address < $1.address
            }
            .map(\.address)
            .uniqued()
    }

    static func isLocalOrLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["),
           let closingBracket = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<closingBracket])
        }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }
        if host.hasPrefix("::ffff:") {
            host = String(host.dropFirst("::ffff:".count))
        }

        if isValidIPv4(host) {
            return host.hasPrefix("127.")
                || isPrivateOrLinkLocalIPv4(host)
        }

        guard isValidIPv6(host) else { return false }
        if host == "::1" {
            return true
        }
        guard let firstByte = ipv6Bytes(host)?.first else {
            return false
        }
        if firstByte == 0xfc || firstByte == 0xfd {
            return true
        }
        guard let bytes = ipv6Bytes(host), bytes.count >= 2 else {
            return false
        }
        return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }

    static func isPrivateOrLinkLocalIPv4(
        _ address: String
    ) -> Bool {
        guard let octets = ipv4Octets(address) else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }

    private static func isValidIPv4(_ address: String) -> Bool {
        ipv4Octets(address) != nil
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        var storage = in_addr()
        guard address.withCString({
            inet_pton(AF_INET, $0, &storage)
        }) == 1 else {
            return nil
        }
        let parts = address.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private static func isValidIPv6(_ address: String) -> Bool {
        ipv6Bytes(address) != nil
    }

    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        var storage = in6_addr()
        guard address.withCString({
            inet_pton(AF_INET6, $0, &storage)
        }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: storage) { Array($0) }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
