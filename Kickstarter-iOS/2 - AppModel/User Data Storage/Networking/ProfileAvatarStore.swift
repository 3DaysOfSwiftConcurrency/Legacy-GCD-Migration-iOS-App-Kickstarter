import Foundation
import KsApi

/// Serializes the existing disk cache away from UI rendering. URLSession's native
/// async operation owns transport cancellation; the Feature owns request identity.
public actor ProfileAvatarStore {
  public static let shared = ProfileAvatarStore()
  private let directory: URL?
  private let download: @Sendable (URL) async throws -> Data
  public init(
    directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
    download: @escaping @Sendable (URL) async throws -> Data = { url in
      try await NetworkingManager.data(from: url)
    }
  ) { self.directory = directory; self.download = download }
  public func loadAvatarBytes(for url: URL) async throws -> Data {
    try Task.checkCancellation()
    // Keep the existing cache name and cache-first/failure behavior.
    guard let directory else { throw URLError(.cannotOpenFile) }
    let cacheFileURL = directory.appendingPathComponent("tabbar-avatar-image-\(url.absoluteString.hashValue).dat")
    if let cachedBytes = try? Data(contentsOf: cacheFileURL) { return cachedBytes }
    let downloadedBytes = try await self.download(url)
    try Task.checkCancellation()
    try? downloadedBytes.write(to: cacheFileURL, options: .atomic)
    return downloadedBytes
  }
}
