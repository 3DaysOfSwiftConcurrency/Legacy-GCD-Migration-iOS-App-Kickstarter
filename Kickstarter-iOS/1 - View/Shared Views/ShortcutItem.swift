import UIKit

public enum ShortcutItem {
  case projectsWeLove
  case recommendedForYou
  case search

  static func items(hasRecommendations: Bool) -> [ShortcutItem] {
    hasRecommendations ? [.recommendedForYou, .projectsWeLove, .search] : [.projectsWeLove, .search]
  }

  public init?(typeString: String) {
    switch typeString {
    case "projects_we_love":
      self = .projectsWeLove
    case "recommended_for_you":
      self = .recommendedForYou
    case "search":
      self = .search
    default:
      return nil
    }
  }

  public var typeString: String {
    switch self {
    case .projectsWeLove:
      return "projects_we_love"
    case .recommendedForYou:
      return "recommended_for_you"
    case .search:
      return "search"
    }
  }
}

extension ShortcutItem: Equatable {}
public func == (lhs: ShortcutItem, rhs: ShortcutItem) -> Bool {
  switch (lhs, rhs) {
  case (.projectsWeLove, .projectsWeLove),
       (.recommendedForYou, .recommendedForYou),
       (.search, .search):
    return true
  default:
    return false
  }
}

extension ShortcutItem {
  public var applicationShortcutItem: UIApplicationShortcutItem {
    switch self {
    case .projectsWeLove:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.Projects_We_Love(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-k"),
        userInfo: nil
      )
    case .recommendedForYou:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.Recommended(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-star"),
        userInfo: nil
      )
    case .search:
      return .init(
        type: self.typeString,
        localizedTitle: Strings.tabbar_search(),
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(templateImageName: "shortcut-icon-search"),
        userInfo: nil
      )
    }
  }
}
