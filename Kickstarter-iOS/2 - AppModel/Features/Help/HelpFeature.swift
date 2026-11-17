import Foundation
import KsApi

/// Owns construction of authenticated requests for Kickstarter help destinations.
@MainActor
public final class HelpFeature {
  private let webBaseURL: @MainActor () -> URL
  private let prepareRequest: @MainActor (URL) -> URLRequest

  public init(
    webBaseURL: @escaping @MainActor () -> URL,
    prepareRequest: @escaping @MainActor (URL) -> URLRequest
  ) {
    self.webBaseURL = webBaseURL
    self.prepareRequest = prepareRequest
  }

  public func request(for helpType: HelpType) -> URLRequest? {
    guard let url = helpType.url(withBaseUrl: self.webBaseURL()) else { return nil }
    return self.prepareRequest(url)
  }
}
