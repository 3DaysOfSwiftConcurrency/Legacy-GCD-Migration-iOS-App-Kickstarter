import Foundation
import KsApi

@MainActor
internal final class HelpWebViewModel {
  private let appLifecycleFeature: AppLifecycleFeature
  private var helpType: HelpType?

  init(appLifecycleFeature: AppLifecycleFeature? = nil) {
    self.appLifecycleFeature = appLifecycleFeature ?? AppModel.shared.appLifecycleFeature
  }

  func configureWith(helpType: HelpType) {
    self.helpType = helpType
  }

  func requestForViewDidLoad() -> URLRequest? {
    guard let url = self.helpType?.url(withBaseUrl: self.appLifecycleFeature.webBaseURL) else {
      return nil
    }
    return self.appLifecycleFeature.preparedWebRequest(for: url)
  }
}
