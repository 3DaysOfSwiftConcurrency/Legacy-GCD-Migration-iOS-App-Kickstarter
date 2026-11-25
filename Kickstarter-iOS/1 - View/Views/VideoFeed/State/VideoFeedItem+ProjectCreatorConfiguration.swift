import KsApi

extension VideoFeedItem: HasProjectCreatorProperties {
  public var projectCreatorProperties: ProjectCreatorProperties {
    ProjectCreatorProperties(
      id: self.projectNumericID,
      name: self.title,
      projectWebURL: self.projectURL
    )
  }
}

extension VideoFeedItem: HasProjectWebURL {
  public var projectWebURL: String { self.projectURL }
}
