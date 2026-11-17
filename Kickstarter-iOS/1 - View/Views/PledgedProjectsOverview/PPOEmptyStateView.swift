import KDS

import SwiftUI

struct PPOEmptyStateView: View {
  let presentation: PPOEmptyStatePresentation
  var onOpenBackedProjects: (() -> Void)?
  var onExploreProjects: (() -> Void)?

  private enum Constants {
    public static let largePadding = Spacing.unit_06
    public static let horizontalPadding = Spacing.unit_04
  }

  var body: some View {
    VStack(alignment: .center) {
      Text(
        self.presentation.title
      )
      .font(Font(UIFont.ksr_title2().bolded))
      .padding(EdgeInsets(
        top: 0,
        leading: Constants.horizontalPadding,
        bottom: Constants.largePadding,
        trailing: Constants.horizontalPadding
      ))
      .multilineTextAlignment(.center)
      .accessibilityAddTraits(.isHeader)

      VStack(spacing: Constants.largePadding) {
        Text(
          self.presentation.description
        )
        .font(Font(UIFont.ksr_body()))
        .multilineTextAlignment(.center)

        if self.presentation.action == .exploreProjects {
          Button(Strings.Explore_projects()) {
            self.onExploreProjects?()
          }
          .buttonStyle(KSRButtonStyleModifier(style: KSRButtonStyle.green))
        } else {
          Button(Strings.See_all_backed__projects()) {
            self.onOpenBackedProjects?()
          }
          .buttonStyle(KSRButtonStyleModifier(style: KSRButtonStyle.green))
        }
      }
      .padding(EdgeInsets(
        top: 0,
        leading: Constants.largePadding,
        bottom: 0,
        trailing: Constants.largePadding
      ))
    }
  }
}

#Preview {
  PPOEmptyStateView(presentation: PPOEmptyStatePresentation(
    title: Strings.No_backings(),
    description: Strings.When_youve_backed_a_project_itll_show_up_here(),
    action: .exploreProjects
  ))
}
