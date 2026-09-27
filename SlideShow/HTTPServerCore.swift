// ============================================================
// HTTPServerCore.swift
// 通用 HTTP/1.1 服务器 —— 只管收发，不关心业务
//
// 这一层刻意不 import UIKit，也不引用 App 里任何类型。
// 好处是它能脱离 iOS 单独编译运行，于是可以在 Mac 上用真 socket
// 跑测试（见 tools/HTTPTest/）。HTTP 解析是整套上传功能里最容易
// 出微妙 bug 的地方，不测一遍不放心。
//
// 只实现需要的子集：
//   * 支持 GET / POST
//   * 支持 Content-Length 请求体
//   * 每条连接处理一个请求就关（Connection: close）
// 不做：keep-alive、分块传输编码、HTTPS、WebSocket
//
// 兼容：iOS 12+ / macOS 10.14+
// ============================================================

import Foundation
import Network

// MARK: - 请求 / 响应

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// 取查询参数，自动做百分号解码
    func param(_ key: String) -> String? {
        guard let raw = query[key] else { return nil }
        return raw.removingPercentEncoding ?? raw
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "text/plain; charset=utf-8"
    var body: Data = Data()
    var extraHeaders: [String: String] = [:]

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     contentType: "text/plain; charset=utf-8",
                     body: Data(message.utf8))
    }

    static func html(_ markup: String) -> HTTPResponse {
        HTTPResponse(status: 200,
                     contentType: "text/html; charset=utf-8",
                     body: Data(markup.utf8))
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            contentType: "application/json; charset=utf-8",
                            body: data)
    }

    static func data(_ data: Data, type: String, filename: String? = nil) -> HTTPResponse {
        var response = HTTPResponse(status: 200, contentType: type, body: data)
        if let filename = filename {
            let encoded = filename.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? filename
            response.extraHeaders["Content-Disposition"] =
                "attachment; filename*=UTF-8''\(encoded)"
        }
        return response
    }

    private static let statusTexts: [Int: String] = [
        200: "OK", 201: "Created", 204: "No Content",
        400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 413: "Payload Too Large",
        500: "Internal Server Error"
    ]

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.statusTexts[status] ?? "OK")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        // 局域网内都是自己人，省掉 CORS 的麻烦
        head += "Access-Control-Allow-Origin: *\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

// MARK: - 单条连接

/// 把 TCP 字节流攒成一个完整的 HTTP 请求
final class HTTPConnection {

    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    /// 请求已完整解析并派发出去
    private var dispatched = false

    /// 收尾只做一次 —— stateUpdateHandler 的 .cancelled 会再进来一趟
    private var didFinish = false

    /// 请求头结束的位置。
    ///
    /// 必须缓存下来：大文件会分成几千个 128 KB 分片到达，
    /// 如果每片都从头搜一次 \r\n\r\n，就是 O(n²) ——
    /// 传 64 MB 要扫几十 GB 内存，设备直接卡死。
    private var headerEnd: Int?
    private var contentLength = 0

    /// 请求头解析结果
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]

    /// 每个分片都会用到，提出来避免反复分配
    private static let headerSeparator = Data("\r\n\r\n".utf8)

    /// 请求头最大 16 KB —— 正常请求头不到 2 KB，超过就是有人在乱发
    private let maxHeaderBytes = 16 * 1024

    /// 请求体上限。整包都在内存里，缓冲区一份、交给业务层时 subdata
    /// 再复制一份，峰值是两倍，所以这个数不能开太大。
    private let maxBodyBytes: Int

    var onRequest: ((HTTPRequest) -> Void)?
    var onFinish: (() -> Void)?

    init(connection: NWConnection,
         queue: DispatchQueue,
         maxBodyBytes: Int = 64 * 1024 * 1024) {
        self.connection = connection
        self.queue = queue
        self.maxBodyBytes = maxBodyBytes
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.didFinish else { return }

            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                if self.parseIfComplete() { return }
            }

            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receive()
        }
    }

    /// 数据够一个完整请求就派发，返回 true 表示这条连接的事已经办完
    private func parseIfComplete() -> Bool {
        // 第一步：找到请求头结束位置，只做一次
        if headerEnd == nil {
            guard let headRange = buffer.range(of: Self.headerSeparator) else {
                if buffer.count > maxHeaderBytes {
                    respond(.text(400, "请求头过大"))
                }
                return dispatched
            }

            guard parseHead(buffer.subdata(in: 0..<headRange.lowerBound)) else {
                return true     // parseHead 失败时已经回过响应了
            }
            headerEnd = headRange.upperBound
        }

        guard let bodyStart = headerEnd else { return true }

        // 第二步：请求体收全了没
        guard buffer.count - bodyStart >= contentLength else {
            return false
        }

        let body = contentLength > 0
            ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()

        dispatched = true
        onRequest?(HTTPRequest(method: method, path: path,
                               query: query, headers: headers, body: body))
        return true
    }

    /// 解析请求头。失败时自己发响应并返回 false。
    private func parseHead(_ headData: Data) -> Bool {
        guard let headText = String(data: headData, encoding: .utf8) else {
            respond(.text(400, "请求头不是 UTF-8"))
            return false
        }

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            respond(.text(400, "空请求"))
            return false
        }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            respond(.text(400, "请求行格式错误"))
            return false
        }

        method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var parsedHeaders: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            parsedHeaders[key] = value
        }
        headers = parsedHeaders

        contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else {
            respond(.text(413, "文件太大"))
            return false
        }

        // 拆出 path 和 query
        path = target
        query = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            let queryString = String(target[target.index(after: mark)...])
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    query[String(parts[0])] = String(parts[1])
                } else if parts.count == 1 {
                    query[String(parts[0])] = ""
                }
            }
        }

        return true
    }

    /// 发一个响应然后关连接
    func respond(_ response: HTTPResponse) {
        dispatched = true
        let payload = response.serialized()
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        connection.cancel()
        onFinish?()
    }

    func abort() {
        finish()
    }
}

// MARK: - 服务器

final class HTTPServer {

    typealias Handler = (HTTPRequest) -> HTTPResponse

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let queue: DispatchQueue
    private let handler: Handler
    private let maxBodyBytes: Int

    /// 依次尝试的端口。第一个被占就试下一个。
    private let ports: [UInt16]

    /// 监听成功，回传实际用的端口
    var onReady: ((UInt16) -> Void)?

    /// 全部端口都失败
    var onError: ((String) -> Void)?

    /// 每次状态变化（用于把 isRunning 同步到 UI）
    var onStopped: (() -> Void)?

    init(ports: [UInt16],
         queue: DispatchQueue = DispatchQueue(label: "httpserver"),
         maxBodyBytes: Int = 64 * 1024 * 1024,
         handler: @escaping Handler) {
        self.ports = ports
        self.queue = queue
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    func start() {
        // 判断必须放进队列里做。
        // 放外面的话，快速连点两次会双双通过 listener == nil 的检查，
        // 起出两个监听器 —— 第二个抢不到端口，第一个就成了没人管的野指针。
        queue.async { [weak self] in
            guard let self = self, self.listener == nil else { return }
            self.startOnPort(index: 0)
        }
    }

    private func startOnPort(index: Int) {
        guard index < ports.count else {
            let message = "端口都被占用了"
            DispatchQueue.main.async { self.onError?(message) }
            return
        }

        let candidate = ports[index]
        guard let nwPort = NWEndpoint.Port(rawValue: candidate) else {
            startOnPort(index: index + 1)
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            startOnPort(index: index + 1)
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async { self.onReady?(candidate) }

            case .failed:
                if self.listener === listener { self.listener = nil }
                listener.cancel()
                self.startOnPort(index: index + 1)

            case .cancelled:
                // 只有「当前这个」监听器被取消才算服务停了。
                // 端口重试时被取消的旧监听器不算 —— 否则它的 .cancelled
                // 可能晚于新监听器的 .ready 到达，把正在跑的服务显示成已停止。
                guard self.listener === listener else { break }
                self.listener = nil
                DispatchQueue.main.async { self.onStopped?() }

            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 先摘掉引用再 cancel，这样上面 .cancelled 里的身份检查
            // 会认作「旧监听器」，不重复触发 onStopped
            let current = self.listener
            self.listener = nil

            for (_, connection) in self.connections {
                connection.abort()
            }
            self.connections.removeAll()

            current?.cancel()
            DispatchQueue.main.async { self.onStopped?() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapper = HTTPConnection(connection: connection,
                                     queue: queue,
                                     maxBodyBytes: maxBodyBytes)
        let key = ObjectIdentifier(connection)

        // wrapper 要弱捕获 —— 这个闭包存在 wrapper 自己身上，
        // 强捕获就成了循环引用，每来一个连接泄漏一个对象
        wrapper.onRequest = { [weak self, weak wrapper] request in
            guard let self = self, let wrapper = wrapper else { return }
            wrapper.respond(self.handler(request))
        }

        wrapper.onFinish = { [weak self] in
            self?.connections.removeValue(forKey: key)
        }

        connections[key] = wrapper
        wrapper.start()
    }
}
