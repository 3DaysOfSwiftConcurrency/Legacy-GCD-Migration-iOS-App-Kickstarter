@testable import Kickstarter_iOS
import Combine
import XCTest

@testable import KsApi

@MainActor
final class PPOContainerViewModelTests: XCTestCase {
  func testAddressAcknowledgedShowsSuccessAndRefreshesOnce() async {
    let model = self.makeModel(MockService(confirmBackingAddressResult: .success(true)))
    var progress: [PPOActionState] = []
    var banners: [MessageBannerType] = []
    var refreshes = 0
    let banner = model.showBanner.sink { banners.append($0.type) }
    let refresh = model.shouldRefresh.sink { refreshes += 1 }
    defer {
      banner.cancel()
      refresh.cancel()
    }
    model.confirmAddress(addressId: "A", backingId: "B") { progress.append($0) }
    XCTAssertEqual(progress, [.confirmed])
    await model.waitForOperations()
    XCTAssertEqual(progress, [.confirmed, .succeeded])
    XCTAssertEqual(banners, [.success])
    XCTAssertEqual(refreshes, 1)
  }
  func testAddressNegativeAcknowledgementPreservesProgressAndErrorBanner() async {
    let model = self.makeModel(MockService(confirmBackingAddressResult: .success(false)))
    var progress: [PPOActionState] = []
    var errors = 0
    var refreshes = 0
    let banner = model.showBanner.sink { if $0.type == .error { errors += 1 } }
    let refresh = model.shouldRefresh.sink { refreshes += 1 }
    defer {
      banner.cancel()
      refresh.cancel()
    }
    model.confirmAddress(addressId: "A", backingId: "B") { progress.append($0) }
    await model.waitForOperations()
    XCTAssertEqual(progress, [.confirmed, .succeeded])
    XCTAssertEqual(errors, 1)
    XCTAssertEqual(refreshes, 0)
  }
  func testAddressFailureDoesNotReportSuccessOrRefresh() async {
    let model = self.makeModel(
      MockService(confirmBackingAddressResult: .failure(.couldNotParseJSON)))
    var progress: [PPOActionState] = []
    var errors = 0
    let banner = model.showBanner.sink { if $0.type == .error { errors += 1 } }
    defer { banner.cancel() }
    model.confirmAddress(addressId: "A", backingId: "B") { progress.append($0) }
    await model.waitForOperations()
    XCTAssertEqual(progress, [.confirmed])
    XCTAssertEqual(errors, 1)
  }
  func testReceiptFailurePublishesOneErrorAndOneRefresh() async {
    let model = self.makeModel(
      MockService(updateRewardReceivedResult: .failure(.couldNotParseJSON)))
    var errors = 0
    var refreshes = 0
    let banner = model.showBanner.sink { if $0.type == .error { errors += 1 } }
    let refresh = model.shouldRefresh.sink { refreshes += 1 }
    defer {
      banner.cancel()
      refresh.cancel()
    }
    model.updateRewardReceived(backingId: "B", rewardReceived: true)
    await model.waitForOperations()
    XCTAssertEqual(errors, 1)
    XCTAssertEqual(refreshes, 1)
  }
  func testReceiptSuccessKeepsOptimisticCardWithoutBannerOrRefresh() async {
    let model = self.makeModel(MockService(updateRewardReceivedResult: .success(true)))
    var banners = 0
    var refreshes = 0
    let banner = model.showBanner.sink { _ in banners += 1 }
    let refresh = model.shouldRefresh.sink { refreshes += 1 }
    defer {
      banner.cancel()
      refresh.cancel()
    }
    model.updateRewardReceived(backingId: "B", rewardReceived: false)
    await model.waitForOperations()
    XCTAssertEqual(banners, 0)
    XCTAssertEqual(refreshes, 0)
  }
  func testActivityBadgeUsesTheActivityFeatureAccount() {
    var user = User.template
    user.unseenActivityCount = 3
    let model = self.makeModel(MockService(), currentUser: { user })
    var badge: TabBarBadge?
    let observation = model.activityBadge.sink { badge = $0 }
    defer { observation.cancel() }

    model.viewWillAppear()

    XCTAssertEqual(badge?.count, 3)
    XCTAssertTrue(model.hasUnseenActivity)
  }

  private func makeModel(
    _ service: MockService, currentUser: @escaping @MainActor () -> User? = { AppEnvironment.current.currentUser }
  ) -> PPOContainerViewModel {
    let sessionFeature = SessionFeature(
      makeProvider: { AsyncSessionProvider(service: service) }, currentUser: currentUser
    )
    return PPOContainerViewModel(
      pledgeFeature: PledgeFeature(
        platform: .live(), sessionFeature: sessionFeature, makeProvider: { AsyncPledgeProvider(service: service) }
      ),
      activityFeature: ActivityFeature(
        sessionFeature: sessionFeature, makeProvider: { AsyncActivityProvider(service: service) }
      )
    )
  }
}
