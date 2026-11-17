import Foundation
import KDS
import KsApi
import Prelude
import Observation
import UIKit

public struct ManageViewPledgeRewardReceivedViewData: Equatable {
  public let project: Project
  public let backerCompleted: Bool
  public let estimatedDeliveryOn: TimeInterval
  public let backingState: Backing.Status
  public let estimatedShipping: String?
  public let pledgeDisclaimerViewHidden: Bool
}

@MainActor @Observable
public final class ManageViewPledgeRewardReceivedViewModel {
  public private(set) var cornerRadius: CGFloat = 0
  public private(set) var estimatedDeliveryDateLabelAttributedText: NSAttributedString?
  public private(set) var estimatedShippingAttributedText: NSAttributedString?
  public private(set) var estimatedShippingHidden = true
  public private(set) var layoutMargins: UIEdgeInsets = .zero
  public private(set) var marginWidth: CGFloat = 0
  public private(set) var pledgeDisclaimerViewHidden = false
  public private(set) var rewardReceived = false
  public private(set) var rewardReceivedHidden = true
  @ObservationIgnored public var onChange: (@MainActor () -> Void)?
  @ObservationIgnored private let pledgeFeature: PledgeFeature
  @ObservationIgnored private let trackToggle: @MainActor (Bool, Project) -> Void
  @ObservationIgnored private let delay: @MainActor () async throws -> Void
  @ObservationIgnored private var observation: (id: UUID, task: Task<Void, Never>)?
  private var configuration: (data: ManageViewPledgeRewardReceivedViewData, session: PledgeFeature.SessionIdentity)?
  private var loaded = false

  public init(
    pledgeFeature: PledgeFeature,
    trackToggle: @escaping @MainActor (Bool, Project) -> Void,
    delay: @escaping @MainActor () async throws -> Void
  ) {
    self.pledgeFeature = pledgeFeature
    self.trackToggle = trackToggle
    self.delay = delay
  }

  public func configureWith(_ data: ManageViewPledgeRewardReceivedViewData) {
    let session = self.pledgeFeature.sessionIdentity
    if let previous = self.configuration,
       previous.session != session || previous.data.project.id != data.project.id ||
       previous.data.project.personalization.backing?.id != data.project.personalization.backing?.id {
      self.observation?.task.cancel()
      self.observation = nil
    }
    self.configuration = (data, session)
    if self.loaded { self.apply(data) }
  }

  public func viewDidLoad() {
    self.loaded = true
    if let data = self.configuration?.data { self.apply(data) }
  }

  private func apply(_ data: ManageViewPledgeRewardReceivedViewData) {
    self.rewardReceived = data.backerCompleted
    self.estimatedDeliveryDateLabelAttributedText = estimatedDeliveryAttributedText(with: data.estimatedDeliveryOn)
    if let shipping = data.estimatedShipping { self.estimatedShippingAttributedText = formatEstimatedShipping(with: shipping) }
    self.estimatedShippingHidden = data.estimatedShipping == nil
    self.rewardReceivedHidden = data.backingState != .collected
    self.cornerRadius = self.rewardReceivedHidden ? 0 : Styles.grid(2)
    self.layoutMargins = self.rewardReceivedHidden ? .zero : .init(all: Styles.gridHalf(5))
    self.marginWidth = self.rewardReceivedHidden ? 0 : 1
    self.pledgeDisclaimerViewHidden = data.pledgeDisclaimerViewHidden
    self.onChange?()
  }

  public func rewardReceivedToggleTapped(isOn: Bool) {
    guard self.loaded, let configuration = self.configuration,
          self.pledgeFeature.sessionIdentity == configuration.session else { return }
    let project = configuration.data.project
    self.trackToggle(isOn, project)
    guard let write = self.pledgeFeature.startReceivedForCurrentUser(projectID: project.id, received: isOn)
    else { return }

    self.observation?.task.cancel()
    let id = UUID()
    let delay = self.delay
    let task = Task { [weak self] in
      defer {
        if self?.observation?.id == id { self?.observation = nil }
      }
      do {
        let backing = try await write.value
        try Task.checkCancellation()
        try await delay()
        try Task.checkCancellation()
        guard let self, self.observation?.id == id,
              self.pledgeFeature.sessionIdentity == configuration.session else { return }
        self.rewardReceived = backing.backerCompleted ?? false
        self.onChange?()
      } catch { }
    }
    self.observation = (id, task)
  }

  func waitForObservation() async { await self.observation?.task.value }
  deinit { self.observation?.task.cancel() }
}

private func formatEstimatedShipping(with shippingRange: String) -> NSAttributedString {
  // In this UI, the title and value are simply separated by a space.
  let totalString = "\(Strings.Estimated_Shipping()) \(shippingRange)"
  return attributedText(totalString: totalString, valueSubstring: shippingRange)
}

@MainActor
private func estimatedDeliveryAttributedText(with date: TimeInterval) -> NSAttributedString {
  let dateString = Format.date(
    secondsInUTC: date,
    template: DateFormatter.monthYear,
    timeZone: UTCTimeZone
  )
  let string = Strings.backing_info_estimated_delivery_date(delivery_date: dateString)

  return attributedText(totalString: string, valueSubstring: dateString)
}

private func attributedText(totalString: String, valueSubstring: String) -> NSAttributedString {
  let font = UIFont.ksr_subhead()

  let attributedText = NSMutableAttributedString(
    attributedString: totalString
      .attributed(
        with: font,
        foregroundColor: LegacyColors.ksr_support_400.uiColor(),
        attributes: [:],
        bolding: [totalString.replacingOccurrences(of: valueSubstring, with: "")]
      )
  )

  attributedText.setAttributes(
    [
      .font: font,
      .foregroundColor: LegacyColors.ksr_support_700.uiColor()
    ],
    range: (totalString as NSString).range(of: valueSubstring)
  )

  return attributedText
}
