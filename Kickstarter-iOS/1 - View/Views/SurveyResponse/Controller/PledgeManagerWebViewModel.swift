import FirebaseCrashlytics
import KsApi
import Prelude
import WebKit

// All requests that can be intercepted from the web view and opened natively
// should be defined in this enum.
public enum PledgeManagerNativeNatigationRequest: Equatable {
  case goToProject(param: Param, refTag: RefTag?)
  case goToUpdate(param: Param, updateId: Int)
  case goToPledge(param: Param)
}

@MainActor
final class PledgeManagerWebViewModel {
  enum Event {
    case dismissViewController
    case goToNativeScreen(PledgeManagerNativeNatigationRequest)
    case presentUpdateVC(Project, Update)
    case goToLoginSignup(LoginIntent)
    case title(String?)
    case webViewLoadRequest(URLRequest)
  }
  var onEvent: ((Event) -> Void)?
  private let pledgeFeature: PledgeFeature
  private let updateRoute = UUID()
  private var initialURL: String?
  private var loaded = false
  private var loggedIn = false
  private var updateTask: Task<Void, Never>?
  private var updateRevision = UUID()

  init(pledgeFeature: PledgeFeature) {
    self.pledgeFeature = pledgeFeature
  }
  deinit {
    self.updateTask?.cancel()
    let pledgeFeature = self.pledgeFeature
    let route = self.updateRoute
    Task { @MainActor in pledgeFeature.releaseRead(route: route) }
  }
  func configureWith(url: String) {
    self.initialURL = url
    self.loadInitialIfReady()
  }
  func viewDidLoad() {
    self.loaded = true
    self.loggedIn = !self.pledgeFeature.requiresPledgeManagerSignIn
    if !self.loggedIn { self.onEvent?(.goToLoginSignup(.generic)) }
    self.loadInitialIfReady()
  }
  func userSessionStarted() {
    self.loggedIn = true
    self.loadInitialIfReady()
  }
  private func loadInitialIfReady() {
    guard self.loaded, self.loggedIn, let initialURL, let url = URL(string: initialURL) else { return }
    let request = URLRequest(url: url)
    self.publishTitle(for: request)
    self.onEvent?(.webViewLoadRequest(self.pledgeFeature.preparedWebRequest(from: request)))
  }
  private func publishTitle(for request: URLRequest) {
    guard isSupportedRequest(request: request, pledgeFeature: self.pledgeFeature), let url = request.url else { return }
    self.onEvent?(.title(url.lastPathComponent == "redeem" ? Strings.Pledge_manager() : nil))
  }
  func closeButtonTapped() {
    self.updateRevision = UUID()
    self.updateTask?.cancel()
    self.pledgeFeature.releaseRead(route: self.updateRoute)
    self.onEvent?(.dismissViewController)
  }
  func fetchUpdateVCData(param: Param, updateId: Int) {
    self.updateTask?.cancel()
    let revision = UUID()
    self.updateRevision = revision
    let pledgeFeature = self.pledgeFeature
    let route = self.updateRoute
    self.updateTask = Task { [weak self] in
      do {
        let (project, update) = try await pledgeFeature.fetchPledgeUpdateContext(route: route, param: param, updateID: updateId)
        guard !Task.isCancelled, let self, self.updateRevision == revision else { return }
        self.onEvent?(.presentUpdateVC(project, update))
      } catch { }
    }
  }
  func waitForUpdate() async { await self.updateTask?.value }
  func decidePolicyFor(navigationAction action: WKNavigationActionData) -> WKNavigationActionPolicy {
    let request = action.request
    self.publishTitle(for: request)
    if isUnpreparedSupportedRequest(request: request, pledgeFeature: self.pledgeFeature) {
      self.onEvent?(.webViewLoadRequest(self.pledgeFeature.preparedWebRequest(from: request)))
    }
    if let native = nativeNavigationRequestForURLRequest(request, pledgeFeature: self.pledgeFeature) { self.onEvent?(.goToNativeScreen(native)) }
    if isStripeNavigationAction(action) { return .allow }
    if isSupportedRequest(request: request, pledgeFeature: self.pledgeFeature) {
      return self.pledgeFeature.isPreparedWebRequest(request) ? .allow : .cancel
    }
    if nativeNavigationRequestForURLRequest(request, pledgeFeature: self.pledgeFeature) != nil { return .cancel }
    if let error = errorForUnrecognizedUrl(request: request, pledgeFeature: self.pledgeFeature) { Crashlytics.crashlytics().record(error: error) }
    if self.pledgeFeature.isKickstarterWebRequest(request) { return .cancel }
    return self.pledgeFeature.allowsUnrecognizedPledgeManagerNavigation ? .allow : .cancel
  }
}

// All navigation requests returned by this function should be passed along to
// the view controller so it can open their native views. Any request that
// doesn't have a corresponding native request will either be displayed in the
// webview or be discarded.
@MainActor
private func nativeNavigationRequestForURLRequest(_ request: URLRequest, pledgeFeature: PledgeFeature)
  -> PledgeManagerNativeNatigationRequest?
{
  switch pledgeFeature.navigationMatch(request) {
  case (.project(let param, .root, let refInfo, _))?:
    return .goToProject(param: param, refTag: refInfo?.refTag)
  case (.project(let param, .pledge, _, _))?:
    return .goToPledge(param: param)
  case (.project(let param, .update(let id, _), _, _))?:
    return .goToUpdate(param: param, updateId: id)
  default: return nil
  }
}

@MainActor
private func isUnpreparedSupportedRequest(request: URLRequest, pledgeFeature: PledgeFeature) -> Bool {
  guard !pledgeFeature.isPreparedWebRequest(request) else { return false }
  return isSupportedRequest(request: request, pledgeFeature: pledgeFeature)
}

@MainActor
private func isSupportedRequest(request: URLRequest, pledgeFeature: PledgeFeature) -> Bool {
  let navigation = pledgeFeature.navigationMatch(request)
  guard case (.project(_, .pledgeManagerWebview, _, _))? = navigation else { return false }
  return true
}

// Returns true if either the url host or the target frame's security origin
// is of the form *.stripe.com, *.stripe.network, or *.stripecdn.com.
@MainActor
private func isStripeNavigationAction(_ actionData: WKNavigationActionData) -> Bool {
  if let host = actionData.request.url?.host, isStripeHost(host) {
    return true
  }
  if let securityOriginHost = actionData.navigationAction?.targetFrame?.securityOrigin.host,
    isStripeHost(securityOriginHost)
  {
    return true
  }
  return false
}

private func isStripeHost(_ host: String) -> Bool {
  let stripeDomains = ["stripe.com", "stripe.network", "stripecdn.com"]

  let withoutSubdomain = host.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
  return stripeDomains.contains(withoutSubdomain)
}

@MainActor
private func errorForUnrecognizedUrl(request: URLRequest, pledgeFeature: PledgeFeature) -> NSError? {
  let errorDomain = "Kickstarter.PledgeManagerWebView"
  enum ErrorCode: Int {
    case unhandledKickstarterUrl = 1
    case unrecognizedUrl = 2
  }

  // If there's no url present, don't log an error. The "about:blank" happens
  // every time the web view loads, so logging these would be too noisy.
  guard let url = request.url, url.absoluteString != "about:blank" else {
    return nil
  }

  if pledgeFeature.isKickstarterWebRequest(request) {
    return NSError(
      domain: errorDomain,
      code: ErrorCode.unhandledKickstarterUrl.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Found unhandled kickstarter url"
      ]
    )
  }

  return NSError(
    domain: errorDomain,
    code: ErrorCode.unrecognizedUrl.rawValue,
    userInfo: [
      NSLocalizedDescriptionKey:
        "Found unrecongnized url request with host: \(url.host() ?? "Unknown")"
    ]
  )
}
