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
    let matched = findCategoryFromRootCategories(
      envelope: envelope, categoryParam: category, subcategoryParam: subcategory
    )
    try await self.waitForDeepLinkResponse(responseDelay)
    try Task.checkCancellation()
    return params |> DiscoveryParams.lens.category .~ matched
  }
}

private func deepLinkCategories(rawParams: [String: String]) -> (Param?, Param?) {
  let parentCategoryParams = rawParams["parent_category_id"]
  let subCategoryParams = rawParams["category_id"]
  var categoryParam: Param?
  var subcategoryParam: Param?

  let rawId: (String?) -> Int? = { rawParam in
    guard let rawParamValue = rawParam else {
      return .none
    }

    return Int(rawParamValue)
  }

  let rawName: (String?) -> String? = { rawParam in
    guard let rawParamValue = rawParam else {
      return .none
    }

    return String(rawParamValue)
  }

  if let categoryId = rawId(parentCategoryParams) {
    categoryParam = Param.id(categoryId)
  } else if let categoryName = rawName(parentCategoryParams) {
    categoryParam = Param.slug(categoryName)
  }

  if let subcategoryId = rawId(subCategoryParams) {
    subcategoryParam = Param.id(subcategoryId)
  } else if let subcategoryName = rawName(subCategoryParams) {
    subcategoryParam = Param.slug(subcategoryName)
  }

  let subCategoryWithNoParentCategory = categoryParam == nil && subcategoryParam != nil

  categoryParam = subCategoryWithNoParentCategory ? subcategoryParam : categoryParam
  subcategoryParam = subCategoryWithNoParentCategory ? nil : subcategoryParam

  return (categoryParam, subcategoryParam)
}

/// Will check id and name of category and subcategory against all available categories and subcategories inside envelope
private func findCategoryFromRootCategories(
  envelope: RootCategoriesEnvelope,
  categoryParam: Param,
  subcategoryParam: Param?
) -> KsApi.Category? {
  let allRootCategoryIdsAndNames = envelope.rootCategories.compactMap { $0 }

  let allSubcategoryIdsAndNames = envelope.rootCategories.compactMap { $0.subcategories?.nodes }
    .flatMap { $0 }

  let allCategoryIdsAndNames = allRootCategoryIdsAndNames + allSubcategoryIdsAndNames

  let routableCategory = allCategoryIdsAndNames.first(where: { category in
    category.intID == categoryParam.id
      || category.name.lowercased() == categoryParam.slug?.lowercased()
  })

  let routableSubcategory =
    routableCategory != nil
    ? allCategoryIdsAndNames.first(where: { category in
      category.intID == subcategoryParam?.id
        || category.name.lowercased()
          == subcategoryParam?.slug?
          .lowercased()
    }) : nil

  return routableSubcategory ?? routableCategory
}
