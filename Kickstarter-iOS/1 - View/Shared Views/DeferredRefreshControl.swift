import Foundation
import UIKit

/// Owns refresh-control presentation, including a minimum visible duration.
/// Feature and ViewModel work completes immediately; this control only decides
/// when its own indicator may disappear.
@MainActor
public final class MinimumVisibleRefreshControl: UIRefreshControl {
  private let clock = ContinuousClock()
  private let minimumVisibleDuration: Duration
  private var pendingStart: Task<Void, Never>?
  private var pendingEnd: Task<Void, Never>?
  private var startID = UUID()
  private var endID = UUID()
  private var visibleSince: ContinuousClock.Instant?

  public override init(frame: CGRect) {
    self.minimumVisibleDuration = .milliseconds(300)
    super.init(frame: frame)
    self.addTarget(self, action: #selector(self.refreshDidBegin), for: .valueChanged)
  }

  public init(frame: CGRect, minimumVisibleDuration: Duration) {
    self.minimumVisibleDuration = minimumVisibleDuration
    super.init(frame: frame)
    self.addTarget(self, action: #selector(self.refreshDidBegin), for: .valueChanged)
  }

  public required init?(coder: NSCoder) {
    self.minimumVisibleDuration = .milliseconds(300)
    super.init(coder: coder)
    self.addTarget(self, action: #selector(self.refreshDidBegin), for: .valueChanged)
  }

  @discardableResult
  public func beginRefreshingAfterLayout() -> Task<Void, Never> {
    if let pendingStart { return pendingStart }
    let id = UUID()
    self.startID = id
    let task = Task { [weak self] in
      defer { if self?.startID == id { self?.pendingStart = nil } }
      await Task.yield()
      guard !Task.isCancelled, let self, self.startID == id else { return }
      if let scrollView = self.superview as? UIScrollView {
        scrollView.layoutIfNeeded()
        if scrollView.contentOffset.y == 0 {
          scrollView.setContentOffset(
            .init(x: scrollView.contentOffset.x, y: -self.frame.height), animated: true
          )
        }
      }
      self.beginRefreshing()
    }
    self.pendingStart = task
    return task
  }

  public override func beginRefreshing() {
    self.cancelPendingEnd()
    super.beginRefreshing()
    self.recordVisibleStart()
  }

  public override func endRefreshing() {
    self.cancelPendingStart()
    guard self.isRefreshing else {
      self.cancelPendingEnd()
      self.visibleSince = nil
      super.endRefreshing()
      return
    }
    guard self.pendingEnd == nil, let visibleSince = self.visibleSince else {
      return
    }
    let remaining = self.minimumVisibleDuration - visibleSince.duration(to: self.clock.now)
    guard remaining > .zero else {
      self.finishRefreshing()
      return
    }
    let id = UUID()
    self.endID = id
    self.pendingEnd = Task { [weak self] in
      do { try await Task.sleep(for: remaining) } catch { return }
      guard let self, !Task.isCancelled, self.endID == id else { return }
      self.pendingEnd = nil
      self.finishRefreshing()
    }
  }

  public override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if self.superview == nil {
      self.cancelPendingStart()
      self.cancelPendingEnd()
      self.visibleSince = nil
    }
  }

  private func cancelPendingStart() {
    self.startID = UUID()
    self.pendingStart?.cancel()
    self.pendingStart = nil
  }

  private func cancelPendingEnd() {
    self.endID = UUID()
    self.pendingEnd?.cancel()
    self.pendingEnd = nil
  }

  private func recordVisibleStart() {
    if self.visibleSince == nil { self.visibleSince = self.clock.now }
  }

  private func finishRefreshing() {
    self.cancelPendingEnd()
    self.visibleSince = nil
    super.endRefreshing()
  }

  @objc private func refreshDidBegin() {
    self.cancelPendingEnd()
    self.recordVisibleStart()
  }

  deinit {
    self.pendingStart?.cancel()
    self.pendingEnd?.cancel()
  }
}
