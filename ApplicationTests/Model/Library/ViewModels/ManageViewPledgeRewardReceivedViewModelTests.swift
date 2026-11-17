@testable import Kickstarter_iOS
import Foundation
@testable import KsApi


import Prelude
import XCTest

@MainActor
final class ManageViewPledgeRewardReceivedViewModelTests: TestCase {

  private func advancePledges(by interval: DispatchTimeInterval = .seconds(0)) async {
    await self.vm.waitForObservation()
    await self.feature.waitForOperations()
  }

  override var requiresSnapshotReferenceSimulator: Bool { false }
  private let sessionFeature = SessionFeature(makeProvider: { AsyncSessionProvider(service: MockService()) })
  private lazy var feature = PledgeFeature(
    platform: .live(),
    sessionFeature: self.sessionFeature,
    makeProvider: {
      precondition(AppEnvironment.current.apiService is MockService)
      return AsyncPledgeProvider(service: AppEnvironment.current.apiService)
    }
  )
  private var trackedToggles: [Bool] = []
  private lazy var vm = ManageViewPledgeRewardReceivedViewModel(
    pledgeFeature: self.feature,
    trackToggle: { [weak self] isOn, _ in self?.trackedToggles.append(isOn) },
    delay: {}
  )

  func testAttributedText() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged,
      estimatedShipping: "About $1-$10",
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    XCTAssertEqual(self.vm.estimatedDeliveryDateLabelAttributedText?.string, "Estimated delivery October 2016")
    XCTAssertEqual(self.vm.estimatedShippingAttributedText?.string, "Estimated Shipping About $1-$10")
    await self.feature.waitForOperations()
  }

  func testRewardReceived_NotReceived() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )

    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    XCTAssertEqual(self.vm.rewardReceived, false)
    await self.feature.waitForOperations()
  }

  func testRewardReceived_Received() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ true

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: true,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )

    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    XCTAssertEqual(self.vm.rewardReceived, true)
    await self.feature.waitForOperations()
  }

  func testRewardReceived_Toggle() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )

    await withEnvironment(apiService: MockService(backingUpdate: .template), currentUser: User.template) {
      self.vm.configureWith(data)
      self.vm.viewDidLoad()

      XCTAssertEqual(self.vm.rewardReceived, false)

      self.vm.rewardReceivedToggleTapped(isOn: true)

      await self.advancePledges(by: AppEnvironment.current.apiDelayInterval)

      XCTAssertEqual(self.vm.rewardReceived, true)

      self.vm.rewardReceivedToggleTapped(isOn: false)

      await self.advancePledges(by: AppEnvironment.current.apiDelayInterval)

      XCTAssertEqual(self.vm.rewardReceived, false)
      await self.feature.waitForOperations()
    }
    await self.feature.waitForOperations()
  }

  func testRapidToggleKeepsLatestDisplayedResult() async {
    let data = ManageViewPledgeRewardReceivedViewData(
      project: .template, backerCompleted: false, estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged, estimatedShipping: nil, pledgeDisclaimerViewHidden: false
    )
    await withEnvironment(apiService: MockService(backingUpdate: .template), currentUser: User.template) {
      self.vm.configureWith(data)
      self.vm.viewDidLoad()
      self.vm.rewardReceivedToggleTapped(isOn: true)
      self.vm.rewardReceivedToggleTapped(isOn: false)
      await self.vm.waitForObservation()
      await self.feature.waitForOperations()
      XCTAssertFalse(self.vm.rewardReceived)
    }
  }

  func testDelayedReceiptCannotUpdateAnotherBackingOfTheSameProject() async {
    let project = Project.template |> Project.lens.personalization.backing .~ Backing.template
    let nextBacking = Backing.template |> Backing.lens.id .~ 54321
    let replacement = project |> Project.lens.personalization.backing .~ nextBacking
    var whenDelayed: (() -> Void)?
    var delays = 0
    let model = ManageViewPledgeRewardReceivedViewModel(
      pledgeFeature: self.feature, trackToggle: { _, _ in },
      delay: {
        delays += 1
        whenDelayed?()
      }
    )
    whenDelayed = { [weak model] in model?.configureWith(self.receiptData(project: replacement)) }

    await withEnvironment(apiService: MockService(backingUpdate: .template), currentUser: .template) {
      model.configureWith(self.receiptData(project: project))
      model.viewDidLoad()
      model.rewardReceivedToggleTapped(isOn: true)
      await model.waitForObservation()
      await self.feature.waitForOperations()

      XCTAssertEqual(delays, 1)
      XCTAssertFalse(model.rewardReceived)
    }
  }

  func testOldSessionCannotSendAToggleUntilThePledgeIsReconfigured() async {
    let data = self.receiptData(project: .template)
    await withEnvironment(apiService: MockService(backingUpdate: .template), currentUser: .template) {
      self.vm.configureWith(data)
      self.vm.viewDidLoad()
      self.sessionFeature.sessionChanged()

      self.vm.rewardReceivedToggleTapped(isOn: true)
      await self.advancePledges()
      XCTAssertTrue(self.trackedToggles.isEmpty)
      XCTAssertFalse(self.vm.rewardReceived)

      self.vm.configureWith(data)
      self.vm.rewardReceivedToggleTapped(isOn: true)
      await self.advancePledges()
      XCTAssertEqual(self.trackedToggles, [true])
      XCTAssertTrue(self.vm.rewardReceived)
    }
  }

  private func receiptData(project: Project) -> ManageViewPledgeRewardReceivedViewData {
    ManageViewPledgeRewardReceivedViewData(
      project: project, backerCompleted: false, estimatedDeliveryOn: 1_475_361_315,
      backingState: .collected, estimatedShipping: nil, pledgeDisclaimerViewHidden: false
    )
  }

  func testRewardReceivedHidden_Dropped() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .dropped,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.rewardReceivedHidden, true)
    await self.feature.waitForOperations()
  }

  func testRewardReceivedHidden_Pledged() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .pledged,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.rewardReceivedHidden, true)
    await self.feature.waitForOperations()
  }

  func testRewardReceivedHidden_Preauth() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .preauth,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.rewardReceivedHidden, true)
    await self.feature.waitForOperations()
  }

  func testRewardReceivedHidden_Canceled() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .canceled,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.rewardReceivedHidden, true)
    await self.feature.waitForOperations()
  }

  func testRewardReceivedHidden_Collected() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .dropped,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: false
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.rewardReceivedHidden, true)
    await self.feature.waitForOperations()
  }

  func testPledgeDisclaimerViewHidden() async {
    let backing = Backing.template
      |> Backing.lens.backerCompleted .~ false

    let project = Project.template
      |> Project.lens.personalization .. Project.Personalization.lens.backing .~ backing

    let data = ManageViewPledgeRewardReceivedViewData(
      project: project,
      backerCompleted: false,
      estimatedDeliveryOn: 1_475_361_315,
      backingState: .dropped,
      estimatedShipping: nil,
      pledgeDisclaimerViewHidden: true
    )


    self.vm.configureWith(data)
    self.vm.viewDidLoad()

    await self.advancePledges()

    XCTAssertEqual(self.vm.pledgeDisclaimerViewHidden, true)
    await self.feature.waitForOperations()
  }
}
