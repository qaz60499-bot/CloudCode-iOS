import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

/// Explicitly opt-in, loopback-only bridge used by the Windows reference controller.
///
/// The bridge is disabled for ordinary launches. It starts only when the process receives
/// `--pc-control-bridge-token=<token>`. All requests must carry the same ephemeral token and the
/// listener is bound to 127.0.0.1 so it can be reached through usbmux port forwarding without
/// exposing a LAN service.
final class PCControlBridge {
    static let defaultPort: UInt16 = 12005
    private static let maximumRequestBytes = 64 * 1024
    private static let maximumTokenLength = 160

    private struct Request: Decodable {
        let token: String
        let command: String
        let args: [String]?
    }

    private let token: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.cloudcode.ios.pc-control-bridge")
    private var listener: NWListener?
    private var backgroundAssertionWorkerPID: Int32?
    private var lastStartupDetail = "not-started"

    private init(token: String, port: UInt16) {
        self.token = token
        self.port = port
    }

    static func requestedByProcessArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> PCControlBridge? {
        let tokenPrefix = "--pc-control-bridge-token="
        let portPrefix = "--pc-control-bridge-port="
        guard let rawToken = arguments.first(where: { $0.hasPrefix(tokenPrefix) }).map({ String($0.dropFirst(tokenPrefix.count)) }),
              isValidToken(rawToken) else {
            return nil
        }

        var resolvedPort = defaultPort
        if let rawPort = arguments.first(where: { $0.hasPrefix(portPrefix) }).map({ String($0.dropFirst(portPrefix.count)) }),
           let parsed = UInt16(rawPort), parsed >= 1024 {
            resolvedPort = parsed
        }
        return PCControlBridge(token: rawToken, port: resolvedPort)
    }

    private static func isValidToken(_ token: String) -> Bool {
        guard token.utf8.count >= 32, token.utf8.count <= maximumTokenLength else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 95, 48...57, 65...90, 97...122: // - _ 0-9 A-Z a-z
                return true
            default:
                return false
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            if let workerPID = self.backgroundAssertionWorkerPID {
                _ = EmbeddedRootHelper.stopBackgroundAssertion(workerPID: workerPID)
                self.backgroundAssertionWorkerPID = nil
            }
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastStartupDetail = "invalid-port"
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: nwPort)
        do {
            let newListener = try NWListener(using: parameters, on: nwPort)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lastStartupDetail = "ready"
                case .failed(let error):
                    self.lastStartupDetail = "listener-failed:\(error)"
                case .cancelled:
                    self.lastStartupDetail = "cancelled"
                default:
                    break
                }
            }
            listener = newListener
            newListener.start(queue: queue)
            lastStartupDetail = "starting"
        } catch {
            lastStartupDetail = "listener-create-failed:\(error)"
            return
        }

        let assertion = EmbeddedRootHelper.startBackgroundAssertion(targetPID: ProcessInfo.processInfo.processIdentifier)
        backgroundAssertionWorkerPID = assertion.workerPID
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }
            if next.count > Self.maximumRequestBytes {
                self.send(["ok": false, "error": "request-too-large"], on: connection)
                return
            }

            if let newline = next.firstIndex(of: 0x0A) {
                let requestData = Data(next[..<newline])
                self.handle(requestData, on: connection)
                return
            }

            if isComplete {
                if next.isEmpty {
                    connection.cancel()
                } else {
                    self.handle(next, on: connection)
                }
                return
            }

            if let error {
                self.send(["ok": false, "error": "receive-failed", "detail": String(describing: error)], on: connection)
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func handle(_ requestData: Data, on connection: NWConnection) {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(Request.self, from: requestData) else {
            send(["ok": false, "error": "invalid-json"], on: connection)
            return
        }
        guard request.token == token else {
            send(["ok": false, "error": "unauthorized"], on: connection)
            return
        }

        let args = request.args ?? []
        let response = execute(command: request.command, args: args)
        send(response, on: connection)
    }

    private func execute(command: String, args: [String]) -> [String: Any] {
        switch command {
        case "health":
            let assertionAlive = backgroundAssertionWorkerPID.map { EmbeddedRootHelper.backgroundAssertionIsAlive(workerPID: $0) } ?? false
            return [
                "ok": true,
                "bridge": "cloudcode-pc-control",
                "version": 1,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "port": Int(port),
                "listener": lastStartupDetail,
                "backgroundAssertion": assertionAlive,
            ]

        case "gui-probe":
            let outcome = EmbeddedRootHelper.guiProbe()
            guard let payload = outcome.payload else {
                return ["ok": false, "error": "gui-probe-unavailable", "detail": outcome.detail]
            }
            return [
                "ok": true,
                "detail": outcome.detail,
                "payload": [
                    "backend": payload.backend,
                    "touch": payload.touch,
                    "gestures": payload.gestures,
                    "textInput": payload.textInput,
                    "screenshot": payload.screenshot,
                    "tree": payload.tree,
                    "verify": payload.verify,
                    "screenWidth": payload.screenWidth,
                    "screenHeight": payload.screenHeight,
                ],
            ]

        case "gui-tree":
            let outcome = EmbeddedRootHelper.guiTree()
            guard let tree = outcome.tree else {
                return ["ok": false, "error": "gui-tree-unavailable", "detail": outcome.detail]
            }
            return ["ok": true, "detail": outcome.detail, "tree": tree]

        case "gui-screenshot":
            let outcome = EmbeddedRootHelper.guiScreenshot()
            guard let data = outcome.data else {
                return ["ok": false, "error": "gui-screenshot-unavailable", "detail": outcome.detail]
            }
            return ["ok": true, "detail": outcome.detail, "jpegBase64": data.base64EncodedString()]

        case "gui-focused-input":
            let outcome = EmbeddedRootHelper.focusedTextInput()
            guard let payload = outcome.payload else {
                return ["ok": false, "error": "focused-input-unavailable", "detail": outcome.detail]
            }
            return [
                "ok": true,
                "detail": outcome.detail,
                "payload": [
                    "runtimeAvailable": payload.runtimeAvailable,
                    "focusedElementAvailable": payload.focusedElementAvailable,
                    "focusedTextInput": payload.focusedTextInput,
                    "role": payload.role,
                    "backend": payload.backend,
                    "pid": Int(payload.pid),
                ],
            ]

        case "gui-tap":
            guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.guiTap(x: x, y: y)
            return ["ok": outcome.success, "detail": outcome.detail]

        case "gui-swipe":
            guard args.count == 5,
                  let x1 = Double(args[0]), let y1 = Double(args[1]),
                  let x2 = Double(args[2]), let y2 = Double(args[3]),
                  let duration = Double(args[4]) else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.guiSwipe(fromX: x1, fromY: y1, toX: x2, toY: y2, duration: duration)
            return ["ok": outcome.success, "detail": outcome.detail]

        case "gui-scroll":
            guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.guiScroll(deltaX: x, deltaY: y)
            return ["ok": outcome.success, "detail": outcome.detail]

        case "gui-back":
            guard args.count == 1 else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.guiNavigateBack(strategy: args[0])
            return ["ok": outcome.success, "detail": outcome.detail]

        case "gui-type":
            guard args.count == 1 else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.guiType(args[0])
            return ["ok": outcome.success, "detail": outcome.detail]

        case "app-launch":
            guard args.count == 1, !args[0].isEmpty else {
                return ["ok": false, "error": "invalid-arguments"]
            }
            let outcome = EmbeddedRootHelper.launch(bundleID: args[0])
            return [
                "ok": outcome.accepted,
                "foregroundVerified": outcome.foregroundVerified,
                "detail": outcome.detail,
            ]

        default:
            return ["ok": false, "error": "unsupported-command"]
        }
    }

    private func send(_ payload: [String: Any], on connection: NWConnection) {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
