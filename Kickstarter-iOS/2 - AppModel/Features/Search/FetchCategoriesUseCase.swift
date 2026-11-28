import Foundation
import KsApi

/// Owns Discovery's category request. Equivalent loads share work; release cancels it.
@MainActor
public final class FetchCategoriesUseCase {
  var onCategories: (([KsApi.Category]) -> Void)?
  var onLoading: ((Bool) -> Void)?
  private var categoryLoadTask: Task<Void, Never>?

  private let cache: @MainActor () -> KSCache
  private let fetch: @MainActor () async throws -> [KsApi.Category]

  public init(
    cache: @escaping @MainActor () -> KSCache,
    fetch: @escaping @MainActor () async throws -> [KsApi.Category]
  ) {
    self.cache = cache
    self.fetch = fetch
  }

  deinit { self.categoryLoadTask?.cancel() }

  public func loadCategories() async {
    await self.startCategoriesLoad().value
  }

  @discardableResult
  public func startCategoriesLoad() -> Task<Void, Never> {
    if let categoryLoadTask = self.categoryLoadTask { return categoryLoadTask }
    let cache = self.cache()
    if let cachedCategories = cache[KSCache.ksr_discoveryFiltersCategories] as? [KsApi.Category] {
      self.onCategories?(cachedCategories)
      if !cachedCategories.isEmpty { return Task {} }
    }
    let fetch = self.fetch
    self.onLoading?(true)
    let task = Task { @MainActor [weak self] in
      defer {
        self?.categoryLoadTask = nil
        self?.onLoading?(false)
      }
      do {
        try Task.checkCancellation()
        let result: Result<[KsApi.Category], Error>
        do {
          result = .success(try await fetch())
        }
        catch { result = .failure(error) }
        try Task.checkCancellation()
        guard let self, self.cache() === cache else { return }
        if case let .success(categories) = result {
          cache[KSCache.ksr_discoveryFiltersCategories] = categories
          self.onCategories?(categories)
        }
      } catch {
        // Preserve the existing silent-error UI; a later load can retry.
      }
    }
    self.categoryLoadTask = task
    return task
  }
}
