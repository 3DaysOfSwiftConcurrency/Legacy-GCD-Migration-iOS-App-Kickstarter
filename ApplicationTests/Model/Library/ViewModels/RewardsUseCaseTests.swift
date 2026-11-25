@testable import Kickstarter_iOS
@testable import KsApi
import XCTest

@MainActor
final class RewardsUseCaseTests: TestCase {
  override var requiresSnapshotReferenceSimulator: Bool { false }
  private var vm: RewardsUseCase!
  private var logins: [LoginIntent] = []
  private var rewards = 0

  override func setUp() async throws {
    try await super.setUp()
    self.vm = RewardsUseCase(isLoggedIn: { AppEnvironment.current.currentUser != nil })
    self.vm.onLogin = { [weak self] in self?.logins.append($0) }
    self.vm.onRewards = { [weak self] in self?.rewards += 1 }
  }

  func testNoTokenValueDoesNotNavigate() {
    self.vm.openRewardsOrRequestLogin()
    XCTAssertEqual(self.rewards, 0)
    XCTAssertTrue(self.logins.isEmpty)
  }

  func testNoSecretTokenAllowsLoggedOutUser() {
    withEnvironment(currentUser: nil) {
      self.vm.setSecretRewardToken(nil)
      self.vm.openRewardsOrRequestLogin()
      XCTAssertEqual(self.rewards, 1)
      XCTAssertTrue(self.logins.isEmpty)
    }
  }

  func testSecretTokenRequiresLogin() {
    withEnvironment(currentUser: nil) {
      self.vm.setSecretRewardToken("secret")
      self.vm.openRewardsOrRequestLogin()
      XCTAssertEqual(self.logins, [.backProject])
      XCTAssertEqual(self.rewards, 0)
    }
  }

  func testSecretTokenAllowsLoggedInUser() {
    withEnvironment(currentUser: .template) {
      self.vm.setSecretRewardToken("secret")
      self.vm.openRewardsOrRequestLogin()
      XCTAssertEqual(self.rewards, 1)
      XCTAssertTrue(self.logins.isEmpty)
    }
  }
}
