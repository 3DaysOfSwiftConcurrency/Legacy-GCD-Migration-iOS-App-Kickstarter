import KsApi

/// Replaceable I/O boundary; SearchFeature owns lookup state and overlap policy.
@MainActor
public protocol SearchLookupProvider {
  var cachedCategories: [KsApi.Category]? { get }
  func cache(categories: [KsApi.Category])
  func fetchCategories() async throws -> [KsApi.Category]
  func fetchDefaultLocations() async throws -> [Location]
  func fetchLocationSuggestions(query: String) async throws -> [Location]
}

/// Uses the existing shared category cache and cancellation-aware API methods.
/// Does not introduce a second cache or start work during construction.
@MainActor
public final class AsyncSearchLookupProvider: SearchLookupProvider {
  private let service: any ServiceType
  private let cacheStore: KSCache

  public init(service: any ServiceType, cache: KSCache) {
    self.service = service
    self.cacheStore = cache
  }

  public var cachedCategories: [KsApi.Category]? {
    self.cacheStore[KSCache.ksr_discoveryFiltersCategories] as? [KsApi.Category]
  }

  public func cache(categories: [KsApi.Category]) {
    self.cacheStore[KSCache.ksr_discoveryFiltersCategories] = categories
  }

  public func fetchCategories() async throws -> [KsApi.Category] {
    try await self.service.fetchSearchCategories().rootCategories
  }

  public func fetchDefaultLocations() async throws -> [Location] {
    try await self.service.fetchSearchDefaultLocations()
  }

  public func fetchLocationSuggestions(query: String) async throws -> [Location] {
    try await self.service.fetchSearchLocations(term: query)
  }
}
