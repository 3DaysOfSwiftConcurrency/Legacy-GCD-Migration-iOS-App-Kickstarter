import Foundation

public protocol DateProtocol {
  var date: Date { get }
  func addingTimeInterval(_: TimeInterval) -> Self
  init()
  init(timeIntervalSince1970: TimeInterval)
  var timeIntervalSince1970: TimeInterval { get }
}

extension Date: DateProtocol {
  public var date: Date {
    return self
  }
}

internal struct MockDate: DateProtocol {
  private let timestamp: TimeInterval

  internal init() {
    self.timestamp = 1_475_361_315
  }

  internal init(timeIntervalSince1970 timestamp: TimeInterval) {
    self.timestamp = timestamp
  }

  internal var timeIntervalSince1970: TimeInterval {
    return self.timestamp
  }

  internal var date: Date {
    return Date(timeIntervalSince1970: self.timestamp)
  }

  internal func addingTimeInterval(_ interval: TimeInterval) -> MockDate {
    return MockDate(timeIntervalSince1970: self.timestamp + interval)
  }
}
