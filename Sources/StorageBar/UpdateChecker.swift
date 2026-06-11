import Foundation

enum UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/daniel-inderos/storage-menu-bar/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/daniel-inderos/storage-menu-bar/releases/latest")!
    // Injectable so tests can stub GitHub without reaching the network.
    static var session: URLSession = .shared

    private struct HTTPStatusError: LocalizedError {
        let statusCode: Int

        var errorDescription: String? {
            "Update check failed with HTTP \(statusCode)."
        }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func normalize(_ version: String) -> String {
            version.hasPrefix("v") ? String(version.dropFirst()) : version
        }
        return normalize(candidate).compare(normalize(current), options: .numeric) == .orderedDescending
    }

    /// Fetches the latest release tag and its web page. Calls back on an arbitrary queue.
    static func fetchLatest(completion: @escaping (Result<(version: String, page: URL), Error>) -> Void) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StorageBar/\(version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                completion(.failure(HTTPStatusError(statusCode: response.statusCode)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                completion(.failure(URLError(.cannotParseResponse)))
                return
            }
            let page = (json["html_url"] as? String).flatMap(URL.init) ?? releasesPage
            completion(.success((tag, page)))
        }.resume()
    }
}
