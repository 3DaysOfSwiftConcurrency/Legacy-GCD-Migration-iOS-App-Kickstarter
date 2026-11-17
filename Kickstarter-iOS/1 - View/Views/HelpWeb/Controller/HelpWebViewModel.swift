import Foundation
import KsApi

@MainActor
internal final class HelpWebViewModel {
  private let helpFeature: HelpFeature
  private var helpType: HelpType?

  init(helpFeature: HelpFeature) {
    self.helpFeature = helpFeature
  }

  func configureWith(helpType: HelpType) {
    self.helpType = helpType
  }

  func requestForViewDidLoad() -> URLRequest? {
    self.helpType.flatMap(self.helpFeature.request(for:))
  }
}
