import Foundation
import KsApi
import Prelude


extension DiscoveryFeature {
  /// Resolves URL filter values through the same category data used by Discovery.
  func parametersForDeepLink(
    _ rawParams: [String: String]?, responseDelay: TimeInterval
  ) async throws -> DiscoveryParams? {
    try Task.checkCancellation()
    guard let rawParams, let params = DiscoveryParams.decodeJSONDictionary(rawParams) else { return nil }
    let (category, subcategory) = deepLinkCategories(rawParams: rawParams)
    guard let category else { return params }
    let envelope = try await self.rootCategories()
    try Task.checkCancellation()
    let matchedCategory = findCategoryFromRootCategories(
      envelope: envelope, categoryParam: category, subcategoryParam: subcategory
    )
    try await self.waitForDeepLinkResponse(responseDelay)
    try Task.checkCancellation()
    return params |> DiscoveryParams.lens.category .~ matchedCategory
  }
}

private func deepLinkCategories(rawParams: [String: String]) -> (Param?, Param?) {
  let parentCategoryQueryValue = rawParams["parent_category_id"]
  let categoryQueryValue = rawParams["category_id"]
  var categoryParam: Param?
  var subcategoryParam: Param?

  let parseCategoryID: (String?) -> Int? = { rawParam in
    guard let rawParamValue = rawParam else {
      return .none
    }

    return Int(rawParamValue)
  }

  let readCategorySlug: (String?) -> String? = { rawParam in
    guard let rawParamValue = rawParam else {
      return .none
    }

    return String(rawParamValue)
  }

  if let categoryId = parseCategoryID(parentCategoryQueryValue) {
    categoryParam = Param.id(categoryId)
  } else if let categoryName = readCategorySlug(parentCategoryQueryValue) {
    categoryParam = Param.slug(categoryName)
  }

  if let subcategoryId = parseCategoryID(categoryQueryValue) {
    subcategoryParam = Param.id(subcategoryId)
  } else if let subcategoryName = readCategorySlug(categoryQueryValue) {
    subcategoryParam = Param.slug(subcategoryName)
  }

  let hasCategoryWithoutParent = categoryParam == nil && subcategoryParam != nil

  categoryParam = hasCategoryWithoutParent ? subcategoryParam : categoryParam
  subcategoryParam = hasCategoryWithoutParent ? nil : subcategoryParam

  return (categoryParam, subcategoryParam)
}

/// Will check id and name of category and subcategory against all available categories and subcategories inside envelope
private func findCategoryFromRootCategories(
  envelope: RootCategoriesEnvelope,
  categoryParam: Param,
  subcategoryParam: Param?
) -> KsApi.Category? {
  let rootCategories = envelope.rootCategories.compactMap { $0 }

  let subcategories = envelope.rootCategories.compactMap { $0.subcategories?.nodes }
    .flatMap { $0 }

  let allCategories = rootCategories + subcategories

  let routableCategory = allCategories.first(where: { category in
    category.intID == categoryParam.id
      || category.name.lowercased() == categoryParam.slug?.lowercased()
  })

  let routableSubcategory =
    routableCategory != nil
    ? allCategories.first(where: { category in
      category.intID == subcategoryParam?.id
        || category.name.lowercased()
          == subcategoryParam?.slug?
          .lowercased()
    }) : nil

  return routableSubcategory ?? routableCategory
}
