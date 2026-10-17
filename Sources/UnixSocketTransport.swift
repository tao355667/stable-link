import Foundation
import Darwin

/// Frequent controller reads stay in process. HTTPS through the local proxy
/// retains curl's existing TLS, proxy, and cancellation behavior.
struct EfficientMihomoTransport: MihomoTransport {
    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        if request.socketPath != nil {
            return try await UnixSocketMihomoTransport().perform(request)
        }
        return try await CurlMihomoTransport().perform(request)
    }
}

struct UnixSocketMihomoTransport: MihomoTransport {
    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        let transaction = UnixHTTPTransaction(request: request)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await transaction.run()
        }, onCancel: { transaction.cancel() })
    }
}

private struct UnixHTTPFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Nonblocking sockets are driven by DispatchSources on one utility queue.
/// Cancellation, deadlines, parsing and completion share this queue; the socket
/// is closed only after every source's cancellation handler has run.
private final class UnixHTTPTransaction: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.xct.vpn-gpt.controller", qos: .utility)
    private let request: MihomoRequest
    private var socket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var sourceCount = 0
    private var timeout: DispatchSourceTimer?
    private var continuation: CheckedContinuation<MihomoResponse, Error>?
    private var parser: HTTPResponseParser
    private var outbound = Data()
    private var written = 0
    private var connecting = false
    private var cancelled = false
    private var finished = false

    init(request: MihomoRequest) {
        self.request = request
        parser = HTTPResponseParser(maximumBytes: max(0, request.maximumBytes), method: request.method)
    }

    func run() async throws -> MihomoResponse {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { self.start(continuation) }
        }
    }

    func cancel() {
        Self.queue.async {
            self.cancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<MihomoResponse, Error>) {
        self.continuation = continuation
        if cancelled { finish(.failure(CancellationError())); return }
        do {
            guard let path = request.socketPath, !path.isEmpty, !path.contains("\0"),
                  request.timeout.isFinite, request.timeout > 0, request.timeout <= 3_600,
                  request.maximumBytes >= 0 else {
                throw UnixHTTPFailure(message: "控制接口请求参数无效。")
            }
            outbound = try requestBytes()
            var address = sockaddr_un()
            let pathBytes = Array(path.utf8) + [0]
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw UnixHTTPFailure(message: "控制套接字路径过长。")
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
            socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { throw posixFailure() }
            let flags = fcntl(socket, F_GETFL)
            guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(socket, F_SETFD, FD_CLOEXEC) == 0 else { throw posixFailure() }
            var noSignal: Int32 = 1
            guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw posixFailure() }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EWOULDBLOCK || errno == EALREADY else { throw posixFailure() }
                connecting = true
            }
            let timeout = DispatchSource.makeTimerSource(queue: Self.queue)
            timeout.schedule(deadline: .now() + request.timeout, leeway: .milliseconds(25))
            timeout.setEventHandler { [weak self] in
                self?.finish(.failure(UnixHTTPFailure(message: "连接超时，请检查代理是否可用。")))
            }
            self.timeout = timeout
            timeout.resume()
            let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: Self.queue)
            sourceCount += 1
            source.setEventHandler { [self] in writeReady() }
            source.setCancelHandler { [self] in sourceCancelled() }
            writeSource = source
            source.resume()
        } catch { finish(.failure(error)) }
    }

    private func requestBytes() throws -> Data {
        guard let url = URLComponents(string: request.url), url.scheme?.lowercased() == "http",
              let host = url.percentEncodedHost, !host.isEmpty,
              url.user == nil, url.password == nil,
              !request.method.isEmpty, request.method.utf8.allSatisfy(Self.isToken) else {
            throw UnixHTTPFailure(message: "控制接口请求地址或方法无效。")
        }
        var target = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { target += "?" + query }
        guard target.hasPrefix("/"), target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              host.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw UnixHTTPFailure(message: "控制接口请求地址无效。")
        }
        let authority = host + (url.port.map { ":\($0)" } ?? "")
        var head = "\(request.method) \(target) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\nAccept: application/json\r\n"
        if let body = request.body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        if let body = request.body { bytes.append(body) }
        return bytes
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    private func writeReady() {
        guard !finished else { return }
        do {
            if connecting {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw posixFailure() }
                guard error == 0 else { throw posixFailure(error) }
                connecting = false
            }
            // Bound one callback's work so cancellation and other requests get
            // their turn even if a caller sends an unusually large JSON body.
            for _ in 0..<8 {
                let count = outbound.withUnsafeBytes { bytes in
                    Darwin.send(socket, bytes.baseAddress!.advanced(by: written), min(16 * 1_024, bytes.count - written), 0)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    throw posixFailure()
                }
                guard count > 0 else { throw UnixHTTPFailure(message: "发送控制接口请求失败。") }
                written += count
                if written == outbound.count {
                    outbound = Data()
                    writeSource?.setEventHandler {}
                    writeSource?.cancel()
                    writeSource = nil
                    let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: Self.queue)
                    sourceCount += 1
                    source.setEventHandler { [self] in readReady() }
                    source.setCancelHandler { [self] in sourceCancelled() }
                    readSource = source
                    source.resume()
                    return
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func readReady() {
        guard !finished else { return }
        do {
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            for _ in 0..<8 {
                let count = bytes.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress!, $0.count, 0) }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    throw posixFailure()
                }
                if let response = try parser.receive(Data(bytes.prefix(count)), ended: count == 0) {
                    finish(.success(response))
                    return
                }
                if count == 0 { throw UnixHTTPFailure(message: "控制接口响应不完整。") }
            }
        } catch { finish(.failure(error)) }
    }

    private func sourceCancelled() {
        sourceCount -= 1
        closeIfFinished()
    }

    private func closeIfFinished() {
        if finished, sourceCount == 0, socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
    }

    private func finish(_ result: Result<MihomoResponse, Error>) {
        // Cancellation can precede run() installing its continuation.
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        timeout?.setEventHandler {}
        timeout?.cancel()
        timeout = nil
        readSource?.setEventHandler {}
        readSource?.cancel()
        readSource = nil
        writeSource?.setEventHandler {}
        writeSource?.cancel()
        writeSource = nil
        closeIfFinished()
        continuation.resume(with: result)
    }

    private func posixFailure(_ code: Int32 = errno) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Incremental HTTP/1 decoding keeps only the bounded body and a small framing
/// buffer. Known lengths finish immediately; a peer cannot extend a deadline by
/// slowly streaming bytes. Chunk metadata and trailers have independent limits.
private struct HTTPResponseParser {
    private enum BodyMode { case length(Int), chunked, untilClose }
    private enum ChunkState { case size, content(Int), delimiter, trailers }
    private static let crlf = Data([13, 10])
    private static let headerEnd = Data([13, 10, 13, 10])
    private static let headerLimit = 32 * 1_024
    private let maximumBytes: Int
    private let method: String
    private var buffer = Data()
    private var body = Data()
    private var status: Int?
    private var mode: BodyMode = .untilClose
    private var chunk: ChunkState = .size
    private var trailerBytes = 0
    private var interimResponses = 0

    init(maximumBytes: Int, method: String) {
        self.maximumBytes = maximumBytes
        self.method = method
    }

    mutating func receive(_ bytes: Data, ended: Bool) throws -> MihomoResponse? {
        buffer.append(bytes)
        while true {
            guard let status else {
                guard let end = buffer.range(of: Self.headerEnd) else {
                    guard buffer.count <= Self.headerLimit else { throw invalid("HTTP 响应头超出大小限制。") }
                    if ended { throw invalid("控制接口响应不完整。") }
                    return nil
                }
                let head = Data(buffer[..<end.lowerBound])
                guard head.count <= Self.headerLimit else { throw invalid("HTTP 响应头超出大小限制。") }
                buffer = Data(buffer[end.upperBound...])
                try parseHeader(head)
                continue
            }
            switch mode {
            case .length(let length):
                let needed = length - body.count
                let count = min(needed, buffer.count)
                try appendBody(buffer.prefix(count))
                consume(count)
                if body.count == length { return MihomoResponse(status: status, body: body) }
            case .untilClose:
                try appendBody(buffer)
                buffer.removeAll(keepingCapacity: true)
                if ended { return MihomoResponse(status: status, body: body) }
            case .chunked:
                switch chunk {
                case .size:
                    guard let line = try takeLine(limit: 8 * 1_024) else { break }
                    let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                        .trimmingCharacters(in: .whitespaces)
                    guard !sizeText.isEmpty, sizeText.utf8.allSatisfy({
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }), let size = Int(sizeText, radix: 16) else { throw invalid("HTTP 分块长度无效。") }
                    guard size <= maximumBytes - body.count else { throw tooLarge() }
                    chunk = size == 0 ? .trailers : .content(size)
                    continue
                case .content(let remaining):
                    let count = min(remaining, buffer.count)
                    try appendBody(buffer.prefix(count))
                    consume(count)
                    if count == remaining { chunk = .delimiter; continue }
                    chunk = .content(remaining - count)
                case .delimiter:
                    guard buffer.count >= 2 else { break }
                    guard buffer.starts(with: Self.crlf) else { throw invalid("HTTP 分块分隔符无效。") }
                    consume(2)
                    chunk = .size
                    continue
                case .trailers:
                    guard let line = try takeLine(limit: Self.headerLimit) else { break }
                    trailerBytes += line.utf8.count + 2
                    guard trailerBytes <= Self.headerLimit else { throw invalid("HTTP 尾部字段超出大小限制。") }
                    if line.isEmpty { return MihomoResponse(status: status, body: body) }
                    guard line.contains(":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                        throw invalid("HTTP 尾部字段无效。")
                    }
                    continue
                }
            }
            if ended { throw invalid("控制接口响应不完整。") }
            return nil
        }
    }

    private mutating func parseHeader(_ data: Data) throws {
        guard let text = String(data: data, encoding: .isoLatin1) else { throw invalid("HTTP 响应头无效。") }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", maxSplits: 2)
        guard first.count >= 2, first[0] == "HTTP/1.1" || first[0] == "HTTP/1.0",
              first[1].count == 3, let code = Int(first[1]), (100...599).contains(code) else {
            throw invalid("未取得有效 HTTP 响应状态。")
        }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw invalid("HTTP 响应字段无效。") }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            fields[name, default: []].append(value)
        }
        if (100..<200).contains(code) {
            interimResponses += 1
            guard code != 101, interimResponses <= 8 else { throw invalid("不支持此 HTTP 响应。") }
            return
        }
        status = code
        if method.uppercased() == "HEAD" || code == 204 || code == 304 {
            mode = .length(0)
        } else if let transfer = fields["transfer-encoding"] {
            guard transfer.count == 1, transfer[0].lowercased() == "chunked",
                  fields["content-length"] == nil else { throw invalid("HTTP 传输长度无效。") }
            mode = .chunked
        } else if let lengths = fields["content-length"] {
            guard Set(lengths).count == 1, let value = lengths.first, !value.isEmpty,
                  value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(value) else {
                throw invalid("HTTP 内容长度无效。")
            }
            guard length <= maximumBytes else { throw tooLarge() }
            mode = .length(length)
        } else { mode = .untilClose }
    }

    private mutating func takeLine(limit: Int) throws -> String? {
        guard let end = buffer.range(of: Self.crlf) else {
            guard buffer.count <= limit else { throw invalid("HTTP 分块字段超出大小限制。") }
            return nil
        }
        let line = Data(buffer[..<end.lowerBound])
        guard line.count <= limit, let text = String(data: line, encoding: .isoLatin1) else {
            throw invalid("HTTP 分块字段无效。")
        }
        buffer = Data(buffer[end.upperBound...])
        return text
    }

    private mutating func appendBody(_ data: Data) throws {
        guard data.count <= maximumBytes - body.count else { throw tooLarge() }
        body.append(data)
    }

    private mutating func consume(_ count: Int) { buffer = Data(buffer.dropFirst(count)) }
    private func invalid(_ message: String) -> UnixHTTPFailure { UnixHTTPFailure(message: message) }
    private func tooLarge() -> UnixHTTPFailure { invalid("控制接口返回内容超出大小限制。") }
}
