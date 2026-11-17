import Foundation
import KsApi

@MainActor
internal final class HelpWebViewModel {
  private let webBaseURL: () -> URL
  private let prepareRequest: (URL) -> URLRequest
  private var helpType: HelpType?

  init(
    webBaseURL: @escaping () -> URL,
    prepareRequest: @escaping (URL) -> URLRequest
  ) {
    self.webBaseURL = webBaseURL
    self.prepareRequest = prepareRequest
  }

  func configureWith(helpType: HelpType) {
    self.helpType = helpType
  }

  func requestForViewDidLoad() -> URLRequest? {
    guard let url = self.helpType?.url(withBaseUrl: self.webBaseURL()) else {
      return nil
    }
    return self.prepareRequest(url)
  }
}
