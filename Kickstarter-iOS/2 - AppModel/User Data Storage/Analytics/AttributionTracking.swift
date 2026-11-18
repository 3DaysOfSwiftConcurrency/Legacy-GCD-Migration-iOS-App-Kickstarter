import Foundation

struct AttributionTracking {
  public enum AttributionEvent: String {
    case projectPageViewed = "Project Page Viewed"
  }

  static func eventParametersJSON(refInfo: RefInfo?) -> String? {
    let sessionRefTag = refInfo?.refTag?.stringTag
    let contextPageURL = refInfo?.deeplinkUrl
    var parameters = [String: String]()
    if let sessionRefTag {
      parameters["session_ref_tag"] = sessionRefTag
    }
    parameters["context_page_url"] = contextPageURL ?? ""

    guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters) else {
      return nil
    }
    return String(data: jsonData, encoding: .utf8)
  }
}
