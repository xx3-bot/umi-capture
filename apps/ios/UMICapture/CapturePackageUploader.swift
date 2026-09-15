import CryptoKit
import Foundation

struct CaptureUploadReceipt: Equatable {
    let uploadID: String
    let storedPath: String?
}

enum CapturePackageUploadError: LocalizedError {
    case invalidFile
    case invalidResponse
    case server(String)
    case retryableInterruption(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Capture ZIP is unavailable for upload."
        case .invalidResponse: return "Receiver returned an invalid upload response."
        case .server(let message): return message
        case .retryableInterruption(let message): return message
        }
    }

    static func isRetryableInterruption(_ error: Error) -> Bool {
        guard let uploadError = error as? CapturePackageUploadError,
              case .retryableInterruption = uploadError else {
            return false
        }
        return true
    }
}

private enum UploadRequestFailure: Error {
    case transient(Error)
    case terminal(Error)
}

private struct CaptureUploadContext {
    let baseURL: URL
    let fileURL: URL
    let deviceID: String
    let size: UInt64
    let digest: String
    let pairingToken: String?
}

private final class CaptureUploadCompletionGate {
    private let lock = NSLock()
    private var finished = false
    private let completion: (Result<CaptureUploadReceipt, Error>) -> Void

    init(
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        self.completion = completion
    }

    func finish(_ result: Result<CaptureUploadReceipt, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}

final class CapturePackageUploader {
    private let session: URLSession
    private let chunkSize = 4 * 1024 * 1024
    private let maximumResumeAttempts: Int
    private let retryDelay: (Int) -> TimeInterval

    init(
        session: URLSession = .shared,
        maximumResumeAttempts: Int = 3,
        retryDelay: @escaping (Int) -> TimeInterval = {
            pow(2.0, Double($0 - 1))
        }
    ) {
        self.session = session
        self.maximumResumeAttempts = max(0, maximumResumeAttempts)
        self.retryDelay = retryDelay
    }

    func upload(
        fileURL: URL,
        expectedIdentity: CapturePackageFileIdentity? = nil,
        host: String,
        port: Int,
        deviceID: String,
        pairingToken: String?,
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        let completionGate = CaptureUploadCompletionGate(
            completion: completion
        )
        DispatchQueue.global(qos: .utility).async {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            ), let size = attributes[.size] as? NSNumber,
                  size.uint64Value > 0
            else {
                completionGate.finish(
                    .failure(CapturePackageUploadError.invalidFile)
                )
                return
            }
            guard expectedIdentity == nil
                    || expectedIdentity?.sizeBytes == size.uint64Value,
                  let digest = expectedIdentity?.sha256
                    ?? Self.sha256(fileURL)
            else {
                completionGate.finish(
                    .failure(CapturePackageUploadError.invalidFile)
                )
                return
            }
            guard let baseURL = URL(string: "http://\(host):\(port)") else {
                completionGate.finish(
                    .failure(CapturePackageUploadError.invalidResponse)
                )
                return
            }
            let context = CaptureUploadContext(
                baseURL: baseURL,
                fileURL: fileURL,
                deviceID: deviceID,
                size: size.uint64Value,
                digest: digest,
                pairingToken: pairingToken
            )
            self.initialize(
                context: context,
                resumeAttemptsRemaining: self.maximumResumeAttempts,
                completion: completionGate.finish
            )
        }
    }

    private func initialize(
        context: CaptureUploadContext,
        resumeAttemptsRemaining: Int,
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        var request = URLRequest(
            url: context.baseURL.appendingPathComponent(
                "api/captures/upload/init"
            )
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: context.pairingToken)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "filename": context.fileURL.lastPathComponent,
            "device_id": context.deviceID,
            "platform": "iOS",
            "size_bytes": context.size,
            "sha256": context.digest,
        ])
        data(request) { result in
            switch result {
            case .failure(let failure):
                self.recover(
                    from: failure,
                    context: context,
                    resumeAttemptsRemaining: resumeAttemptsRemaining,
                    completion: completion
                )
            case .success(let json):
                guard let uploadID = json["upload_id"] as? String,
                      !uploadID.isEmpty,
                      let offset = (json["next_offset"] as? NSNumber)?.uint64Value,
                      offset <= context.size,
                      let complete = json["complete"] as? Bool else {
                    completion(
                        .failure(CapturePackageUploadError.invalidResponse)
                    )
                    return
                }
                if complete {
                    completion(.success(CaptureUploadReceipt(
                        uploadID: uploadID, storedPath: json["stored_path"] as? String
                    )))
                    return
                }
                self.sendChunks(
                    context: context,
                    uploadID: uploadID,
                    offset: offset,
                    resumeAttemptsRemaining: resumeAttemptsRemaining,
                    completion: completion
                )
            }
        }
    }

    private func sendChunks(
        context: CaptureUploadContext,
        uploadID: String,
        offset: UInt64,
        resumeAttemptsRemaining: Int,
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        guard offset < context.size else {
            finish(
                context: context,
                uploadID: uploadID,
                resumeAttemptsRemaining: resumeAttemptsRemaining,
                completion: completion
            )
            return
        }
        guard let handle = try? FileHandle(
            forReadingFrom: context.fileURL
        ) else {
            completion(.failure(CapturePackageUploadError.invalidFile))
            return
        }
        do {
            try handle.seek(toOffset: offset)
            let body = try handle.read(
                upToCount: min(chunkSize, Int(context.size - offset))
            ) ?? Data()
            try handle.close()
            guard !body.isEmpty else {
                throw CapturePackageUploadError.invalidFile
            }
            var request = URLRequest(
                url: context.baseURL.appendingPathComponent(
                    "api/captures/upload/\(uploadID)"
                )
            )
            request.httpMethod = "PUT"
            request.setValue(String(offset), forHTTPHeaderField: "X-Upload-Offset")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            authorize(&request, token: context.pairingToken)
            request.httpBody = body
            data(request) { result in
                switch result {
                case .failure(let failure):
                    self.recover(
                        from: failure,
                        context: context,
                        resumeAttemptsRemaining: resumeAttemptsRemaining,
                        completion: completion
                    )
                case .success(let json):
                    guard let next = (json["next_offset"] as? NSNumber)?.uint64Value,
                          next > offset,
                          next <= context.size else {
                        completion(
                            .failure(
                                CapturePackageUploadError.invalidResponse
                            )
                        )
                        return
                    }
                    self.sendChunks(
                        context: context,
                        uploadID: uploadID,
                        offset: next,
                        resumeAttemptsRemaining: resumeAttemptsRemaining,
                        completion: completion
                    )
                }
            }
        } catch {
            try? handle.close()
            completion(.failure(error))
        }
    }

    private func finish(
        context: CaptureUploadContext,
        uploadID: String,
        resumeAttemptsRemaining: Int,
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        var request = URLRequest(
            url: context.baseURL.appendingPathComponent(
                "api/captures/upload/\(uploadID)/finish"
            )
        )
        request.httpMethod = "POST"
        request.httpBody = Data()
        authorize(&request, token: context.pairingToken)
        data(request) { result in
            switch result {
            case .failure(let failure):
                self.recover(
                    from: failure,
                    context: context,
                    resumeAttemptsRemaining: resumeAttemptsRemaining,
                    completion: completion
                )
            case .success(let json):
                guard json["complete"] as? Bool == true else {
                    completion(
                        .failure(CapturePackageUploadError.invalidResponse)
                    )
                    return
                }
                completion(.success(CaptureUploadReceipt(
                    uploadID: uploadID, storedPath: json["stored_path"] as? String
                )))
            }
        }
    }

    private func recover(
        from failure: UploadRequestFailure,
        context: CaptureUploadContext,
        resumeAttemptsRemaining: Int,
        completion: @escaping (Result<CaptureUploadReceipt, Error>) -> Void
    ) {
        switch failure {
        case .terminal(let error):
            completion(.failure(error))
        case .transient(let error):
            guard resumeAttemptsRemaining > 0 else {
                completion(
                    .failure(
                        CapturePackageUploadError.retryableInterruption(
                            error.localizedDescription
                        )
                    )
                )
                return
            }
            let attempt = maximumResumeAttempts
                - resumeAttemptsRemaining + 1
            let delay = max(0, retryDelay(attempt))
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delay
            ) {
                self.initialize(
                    context: context,
                    resumeAttemptsRemaining:
                        resumeAttemptsRemaining - 1,
                    completion: completion
                )
            }
        }
    }

    private func data(
        _ request: URLRequest,
        completion: @escaping (
            Result<[String: Any], UploadRequestFailure>
        ) -> Void
    ) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.transient(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(
                    .failure(
                        .terminal(CapturePackageUploadError.invalidResponse)
                    )
                )
                return
            }
            let json = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0)
                    as? [String: Any]
            }
            guard (200..<300).contains(http.statusCode) else {
                let error = CapturePackageUploadError.server(
                    json?["error"] as? String
                        ?? "Receiver upload failed (HTTP \(http.statusCode))."
                )
                let failure: UploadRequestFailure =
                    (500..<600).contains(http.statusCode)
                    ? .transient(error)
                    : .terminal(error)
                completion(.failure(failure))
                return
            }
            guard let json else {
                completion(
                    .failure(
                        .terminal(CapturePackageUploadError.invalidResponse)
                    )
                )
                return
            }
            completion(.success(json))
        }.resume()
    }

    private func authorize(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue(
                token,
                forHTTPHeaderField: "X-iPhoneVIO-Pairing-Token"
            )
        }
    }

    private static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try autoreleasepool(invoking: {
                try handle.read(upToCount: 1_048_576)
            }), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
}
