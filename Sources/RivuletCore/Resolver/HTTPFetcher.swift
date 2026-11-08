import Foundation

struct HTTPResult: Sendable {
    var status: Int
    var headers: [String: String]   // lowercased keys
    var body: Data
    var url: URL
    var truncated: Bool
}

/// Small callback based HTTP client with a private cookie jar, redirect scheme
/// filtering and a response body cap. One instance per resolve.
final class HTTPFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        var data = Data()
        var response: HTTPURLResponse?
        var truncated = false
        let maxBody: Int
        let completion: (Result<HTTPResult, Error>) -> Void
        init(maxBody: Int, completion: @escaping (Result<HTTPResult, Error>) -> Void) {
            self.maxBody = maxBody
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private var session: URLSession!
    let cookies: HTTPCookieStorage

    init(timeout: TimeInterval = 20, resourceTimeout: TimeInterval = 60) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = resourceTimeout
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cookies = cfg.httpCookieStorage ?? HTTPCookieStorage.shared
        super.init()
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    func perform(method: String, url: URL, headers: [String: String], body: Data?,
                 timeout: TimeInterval? = nil, maxBody: Int = ResolverLimits.maxBodyBytes,
                 completion: @escaping (Result<HTTPResult, Error>) -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion(.failure(ResolverError("Only http and https URLs are allowed")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout, timeout > 0 { req.timeoutInterval = timeout }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let task = session.dataTask(with: req)
        lock.lock()
        states[task.taskIdentifier] = TaskState(maxBody: maxBody, completion: completion)
        lock.unlock()
        task.resume()
    }

    func perform(method: String, url: URL, headers: [String: String], body: Data? = nil,
                 timeout: TimeInterval? = nil, maxBody: Int = ResolverLimits.maxBodyBytes) async -> Result<HTTPResult, Error> {
        await withCheckedContinuation { cont in
            perform(method: method, url: url, headers: headers, body: body, timeout: timeout, maxBody: maxBody) { cont.resume(returning: $0) }
        }
    }

    func cookieHeader(for url: URL) -> String {
        let list = cookies.cookies(for: url) ?? []
        return list.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: delegate

    private func state(_ task: URLSessionTask) -> TaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "http" || scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        state(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(dataTask) else { return }
        let room = st.maxBody - st.data.count
        if data.count >= room {
            if room > 0 { st.data.append(data.prefix(room)) }
            st.truncated = true
            dataTask.cancel()
        } else {
            st.data.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let st = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let st else { return }
        guard let resp = st.response else {
            st.completion(.failure(error ?? ResolverError("No response")))
            return
        }
        if let error, !st.truncated {
            st.completion(.failure(error))
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in resp.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        st.completion(.success(HTTPResult(status: resp.statusCode, headers: headers, body: st.data,
                                          url: resp.url ?? task.originalRequest?.url ?? URL(fileURLWithPath: "/"),
                                          truncated: st.truncated)))
    }
}
