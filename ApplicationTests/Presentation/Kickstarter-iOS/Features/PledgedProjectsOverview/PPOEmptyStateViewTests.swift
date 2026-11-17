@testable import Kickstarter_iOS



import SnapshotTesting
import SwiftUI
import XCTest

final class PPOEmptyStateViewTests: TestCase {
  func testEmptyStateView() {
    forEachScreenshotType { type in
      withEnvironment(language: type.language) {
        let view = PPOEmptyStateView(presentation: .init(
          title: Strings.No_backings(),
          description: Strings.When_youve_backed_a_project_itll_show_up_here(),
          action: .exploreProjects
        ))
        assertSnapshot(
          forSwiftUIView: view,
          withType: type
        )
      }
    }
  }

  func testEmptyStateView_PPOV2() {
    let language = Language.en
    let device = Device.phone4_7inch
    let orientation = Orientation.landscape

    withEnvironment(language: language) {
      let size = device.deviceSize(in: orientation)
      let view = PPOEmptyStateView(presentation: .init(
        title: Strings.No_funded_backings(),
        description: Strings.When_projects_youve_backed_have_successfully_funded_youll_see_them_here(),
        action: .backedProjects
      )).frame(width: size.width, height: size.height)
      assertSnapshot(
        of: view,
        as: .image,
        named: "lang_\(language.rawValue)"
      )
    }
  }

  // The only difference between v1 and v2 is a strings change. Test v1 in english only.
  func testEmptyStateView_PPOV1() {
    withEnvironment(language: Language.en) {
      let size = Device.phone5_8inch.deviceSize
      let view = PPOEmptyStateView(presentation: .init(
        title: Strings.Youre_all_caught_up(),
        description: Strings.When_projects_youve_backed_need_your_attention_youll_see_them_here(),
        action: .backedProjects
      )).frame(width: size.width, height: size.height)
      assertSnapshot(
        of: view,
        as: .image,
        named: "lang_en"
      )
    }
  }
}
