import Foundation

public struct ReleaseConfiguration: Equatable {
    public let feedURL: URL
    public let publicKey: String
    // Distribution settings are compiled into the signed bundle, never downloaded
    // from arbitrary user input. Development builds without a feed stay offline.
    public init?(feed: String?, publicKey: String?) {
        guard let feed, let url = URL(string: feed), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 6, parts[2...] == ["releases", "latest", "download", "appcast.xml"],
              parts.prefix(2).allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else { return nil }
        self.feedURL = url; self.publicKey = publicKey
    }
}

public enum WelcomeProgress {
    private static let key = "welcomeCompletedVersion"
    public static func shouldPresent(defaults: UserDefaults = .standard) -> Bool { defaults.integer(forKey: key) < 1 }
    public static func complete(defaults: UserDefaults = .standard) { defaults.set(1, forKey: key) }
}
