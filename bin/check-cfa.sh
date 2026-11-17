#!/bin/sh
# CFA migration checks by Matthew Thomas.
set -eu

reject_matches() {
  rule=$1
  pattern=$2
  shift 2
  if git grep -n -E "$pattern" -- "$@"; then
    printf '%s\n' "$rule" >&2
    return 1
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      return "$status"
    fi
  fi
}

app_view='Kickstarter-iOS/1 - View'
app_model='Kickstarter-iOS/2 - AppModel'
root_view_model="$app_view/Views/RootTabBar/RootViewModel.swift"
delegate_handler="$app_view/AppDelegateViewModel.swift"
pledge_view_model="$app_view/Views/PledgeView/Controllers/PledgeViewModel.swift"
post_campaign_view_model="$app_view/Views/PledgeView/Controllers/PostCampaignCheckoutViewModel.swift"
project_page_view_model="$app_view/Views/ProjectPage/Controller/ProjectPageViewModel.swift"

test -f "$root_view_model"
test -f "$delegate_handler"
test -f "$pledge_view_model"
test -f "$post_campaign_view_model"
test -f "$project_page_view_model"
reject_matches 'RootViewModel must receive its dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$root_view_model"
reject_matches 'The delegate handler must receive application dependencies explicitly.' \
  'AppModel[.]shared' "$delegate_handler"
reject_matches 'Checkout view models must receive dependencies from their controllers.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$pledge_view_model" "$post_campaign_view_model"
reject_matches 'ProjectPageViewModel must receive dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$project_page_view_model"
reject_matches 'Application lifecycle signals belong at the AppModel boundary.' \
  'AppLifecycleFeature|appLifecycleFeature' "$app_view" "$app_model"
