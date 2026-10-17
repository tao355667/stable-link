import Foundation
import Darwin

private struct NativeTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NativeTestFailure(description: message) }
}

/// A local raw HTTP fixture deliberately fragments protocol boundaries. It has
/// no TCP listener, never contacts Clash, and owns all mock PUT requests.
private final class UnixFixture {
    let process = Process()
    let root: URL
    let socket: String
    private let lifetime = Pipe()

    init(root: URL) throws {
        self.root = root
        socket = root.appendingPathComponent("controller.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
import json, os, pathlib, socket, sys, threading, time
root = pathlib.Path(sys.argv[1])
sock_path = str(root / 'controller.sock')
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(32)
server.settimeout(.1)
stop = threading.Event()
def lifetime():
    sys.stdin.buffer.read()
    stop.set()
threading.Thread(target=lifetime, daemon=True).start()
def mark(prefix, route):
    (root / (prefix + route.strip('/'))).write_text('1')
def serve(conn):
    route = '/unknown'
    try:
        with conn:
            conn.settimeout(2)
            raw = b''
            while b'\r\n\r\n' not in raw:
                block = conn.recv(8192)
                if not block: return
                raw += block
            head, body = raw.split(b'\r\n\r\n', 1)
            method, target, _ = head.split(b'\r\n')[0].decode().split(' ', 2)
            route = target.split('?')[0]
            fields = dict(line.decode().split(':', 1) for line in head.split(b'\r\n')[1:])
            length = int(fields.get('Content-Length', '0'))
            while len(body) < length:
                block = conn.recv(8192)
                if not block: return
                body += block
            mark('accepted-', route)
            if route.startswith('/hang-'):
                while conn.recv(1024): pass
                return
            fixed_body = 'node 日本 / body\n'.encode()
            if route == '/fixed':
                response = b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(fixed_body)).encode() + b'\r\n\r\n' + fixed_body
            elif route == '/chunked':
                response = (b'HTTP/1.1 100 Continue\r\n\r\n'
                    b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'
                    b'5;test=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Result: ok\r\n\r\n')
            elif route == '/until-close':
                response = b'HTTP/1.0 200 OK\r\nConnection: close\r\n\r\nclose body'
            elif route == '/non-success':
                response = b'HTTP/1.1 503 Unavailable\r\nContent-Length: 10\r\n\r\nkeep-error'
            elif route == '/echo':
                encoded = json.dumps({'method': method, 'target': target,
                    'body': json.loads(body[:length]), 'content_type': fields.get('Content-Type', '').strip()},
                    ensure_ascii=False).encode()
                response = b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(encoded)).encode() + b'\r\n\r\n' + encoded
            elif route == '/empty':
                response = b'HTTP/1.1 204 No Content\r\n\r\n'
            else:
                responses = {
                    '/short': b'HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nabc',
                    '/oversize-length': b'HTTP/1.1 200 OK\r\nContent-Length: 33\r\n\r\n',
                    '/oversize-close': b'HTTP/1.1 200 OK\r\n\r\n' + b'x' * 33,
                    '/oversize-chunk': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n21\r\n',
                    '/huge-header': b'HTTP/1.1 200 OK\r\nX-Huge: ' + b'x' * 33000 + b'\r\n\r\n',
                    '/bad-chunk': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\ngg\r\n',
                    '/bad-delimiter': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxXY0\r\n\r\n',
                    '/short-chunk': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab',
                    '/huge-chunk-line': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n' + b'1' * 9000,
                    '/huge-trailer': b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: ' + b'x' * 33000 + b'\r\n\r\n',
                    '/conflicting-length': b'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx',
                    '/conflicting-framing': b'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx',
                    '/bad-status': b'NOPE\r\n\r\n',
                }
                response = responses[route]
            if route in ('/fixed', '/chunked'):
                for offset in range(0, len(response), 3):
                    conn.sendall(response[offset:offset+3])
                    time.sleep(.001)
            else:
                conn.sendall(response)
            # Known-length, chunked and no-content replies must complete without
            # waiting for the peer to close. EOF also confirms client cleanup.
            if route in ('/fixed', '/chunked', '/empty'):
                while conn.recv(1024): pass
    except (OSError, ValueError, KeyError):
        pass
    finally:
        try: mark('closed-', route)
        except OSError: pass
(root / 'ready').write_text('1')
while not stop.is_set():
    try:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()
    except socket.timeout:
        continue
server.close()
try: os.unlink(sock_path)
except OSError: pass
"""#
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, root.path]
        process.standardInput = lifetime
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try lifetime.fileHandleForReading.close()
    }

    func waitFor(_ marker: String, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(marker).path) { return }
            try expect(process.isRunning, "Unix fixture exited before \(marker)")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativeTestFailure(description: "Fixture did not observe \(marker) within \(timeout)s")
    }

    func request(_ path: String, timeout: TimeInterval = 0.8, limit: Int = 1024) -> MihomoRequest {
        MihomoRequest(url: "http://localhost\(path)", socketPath: socket,
                      timeout: timeout, maximumBytes: limit)
    }

    func stop() {
        try? lifetime.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}

private func requireFailure(_ request: MihomoRequest) async throws {
    do {
        _ = try await UnixSocketMihomoTransport().perform(request)
    } catch { return }
    throw NativeTestFailure(description: "Invalid request/response unexpectedly succeeded: \(request.url)")
}

@main
private struct NativeTransportTests {
    static func main() async {
        // Avoid an indefinite test hang even if a regression stops resuming an
        // async continuation. The fixture also exits when its stdin reaches EOF.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 15)
        watchdog.setEventHandler {
            fputs("FAIL native transport tests exceeded 15 seconds\n", stderr)
            exit(2)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        do {
            try expect(CommandLine.arguments.count == 2, "Pass an isolated short temporary directory")
            let fixture = try UnixFixture(root: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture"))
            defer { fixture.stop() }
            try await fixture.waitFor("ready", timeout: 2)
            let transport = UnixSocketMihomoTransport()

            let fixed = try await transport.perform(fixture.request("/fixed"))
            try expect(fixed.status == 200 && fixed.body == Data("node 日本 / body\n".utf8), "Fragmented Content-Length response changed")
            try await fixture.waitFor("closed-fixed")
            print("PASS Content-Length framing and early connection cleanup")

            let chunked = try await transport.perform(fixture.request("/chunked"))
            try expect(chunked.status == 200 && chunked.body == Data("hello world".utf8), "Fragmented chunked response/trailers changed")
            try await fixture.waitFor("closed-chunked")
            print("PASS fragmented chunk boundaries, extensions, trailers and interim status")

            let closed = try await transport.perform(fixture.request("/until-close"))
            let empty = try await transport.perform(fixture.request("/empty", limit: 0))
            try expect(closed.body == Data("close body".utf8), "Until-close body changed")
            try expect(empty.status == 204 && empty.body.isEmpty, "204 must complete without waiting for EOF")
            try await fixture.waitFor("closed-empty")
            print("PASS until-close and empty response framing")

            let failedHTTP = try await transport.perform(fixture.request("/non-success"))
            try expect(failedHTTP.status == 503 && failedHTTP.body == Data("keep-error".utf8), "Non-2xx status/body must remain intact")
            print("PASS non-2xx status and body preservation")

            var put = fixture.request("/echo?key=%E6%97%A5%E6%9C%AC%2F%3F%23")
            put.method = "PUT"
            put.body = try JSONSerialization.data(withJSONObject: ["name": "日本 / 节点 ?+#%", "enabled": true])
            let echo = try await transport.perform(put)
            let echoed = try JSONSerialization.jsonObject(with: echo.body) as? [String: Any]
            let echoedBody = echoed?["body"] as? [String: Any]
            try expect(echoed?["method"] as? String == "PUT", "Fixture did not receive PUT")
            try expect(echoed?["target"] as? String == "/echo?key=%E6%97%A5%E6%9C%AC%2F%3F%23", "Encoded request target changed")
            try expect(echoed?["content_type"] as? String == "application/json", "PUT content type is missing")
            try expect(echoedBody?["name"] as? String == "日本 / 节点 ?+#%" && echoedBody?["enabled"] as? Bool == true, "Structured UTF-8 PUT body changed")
            print("PASS mock-only PUT method, encoded target and structured body")

            let timeoutStart = Date()
            try await requireFailure(fixture.request("/hang-timeout", timeout: 0.15))
            try expect(Date().timeIntervalSince(timeoutStart) < 1, "Timeout did not bound the request")
            try await fixture.waitFor("closed-hang-timeout")
            for index in 0..<4 {
                let path = "/hang-cancel-\(index)"
                let request = fixture.request(path, timeout: 5)
                let task = Task { try await transport.perform(request) }
                try await fixture.waitFor("accepted-\(path.dropFirst())")
                let began = Date()
                task.cancel()
                do {
                    _ = try await task.value
                    throw NativeTestFailure(description: "Cancelled request unexpectedly succeeded")
                } catch is CancellationError {
                    // The transport's public cancellation contract.
                }
                try expect(Date().timeIntervalSince(began) < 0.5, "Cancellation did not finish promptly")
                try await fixture.waitFor("closed-\(path.dropFirst())")
            }
            let cancelled = Task { try await transport.perform(fixture.request("/must-not-connect")) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw NativeTestFailure(description: "Pre-cancelled request unexpectedly succeeded")
            } catch is CancellationError { }
            print("PASS deadline and repeated cancellation close peer connections")

            let badResponses = ["short", "oversize-length", "oversize-close", "oversize-chunk",
                                "huge-header", "bad-chunk", "bad-delimiter", "short-chunk",
                                "huge-chunk-line", "huge-trailer", "conflicting-length",
                                "conflicting-framing", "bad-status"]
            for path in badResponses {
                try await requireFailure(fixture.request("/\(path)", limit: 32))
                try await fixture.waitFor("closed-\(path)")
            }
            print("PASS \(badResponses.count) incomplete, oversized and malformed response cases")

            var invalid: [MihomoRequest] = [
                MihomoRequest(url: "http://localhost/", socketPath: nil, timeout: 0.2),
                MihomoRequest(url: "http://localhost/", socketPath: "", timeout: 0.2),
                MihomoRequest(url: "http://localhost/", socketPath: "invalid\0socket", timeout: 0.2),
                MihomoRequest(url: "https://localhost/", socketPath: fixture.socket, timeout: 0.2),
                MihomoRequest(url: "http://user:password@localhost/", socketPath: fixture.socket, timeout: 0.2),
                MihomoRequest(url: "file:///tmp/example", socketPath: fixture.socket, timeout: 0.2),
                fixture.request("/invalid", timeout: 0),
                fixture.request("/invalid", timeout: .nan),
                fixture.request("/invalid", limit: -1),
            ]
            var badMethod = fixture.request("/invalid")
            badMethod.method = "GET\r\nInjected: true"
            invalid.append(badMethod)
            for request in invalid { try await requireFailure(request) }
            let missing = MihomoRequest(url: "http://localhost/", socketPath: fixture.root.appendingPathComponent("missing.sock").path, timeout: 0.15)
            try await requireFailure(missing)
            print("PASS \(invalid.count + 1) invalid input and missing-socket cases")
            print("Native transport: 8 groups passed; all requests used an isolated mock Unix socket.")
        } catch {
            fputs("FAIL native transport: \(error)\n", stderr)
            exit(1)
        }
    }
}
