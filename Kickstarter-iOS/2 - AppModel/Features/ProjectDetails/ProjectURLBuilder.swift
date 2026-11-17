import Foundation
import KsApi

public func getProjectBackingDetailsURL(with project: Project, webBaseURL: URL) -> URL? {
  let urlString =
    "\(webBaseURL)/projects/\(project.creator.id)/\(project.slug)/backing/details"

  return URL(string: urlString)
}
