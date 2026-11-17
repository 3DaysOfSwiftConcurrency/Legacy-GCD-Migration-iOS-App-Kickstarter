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
manage_pledge_view_model="$app_view/Views/ManagePledge/Controllers/ManagePledgeViewModel.swift"
cancel_pledge_view_model="$app_view/Views/CancelPledge/Controller/CancelPledgeViewModel.swift"
project_page_view_model="$app_view/Views/ProjectPage/Controller/ProjectPageViewModel.swift"
discovery_feature="$app_model/Features/Discovery/DiscoveryFeature.swift"

test -f "$root_view_model"
test -f "$delegate_handler"
test -f "$pledge_view_model"
test -f "$post_campaign_view_model"
test -f "$manage_pledge_view_model"
test -f "$cancel_pledge_view_model"
test -f "$project_page_view_model"
test -f "$discovery_feature"
reject_matches 'RootViewModel must receive its dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$root_view_model"
reject_matches 'The delegate handler must receive application dependencies explicitly.' \
  'AppModel[.]shared' "$delegate_handler"
reject_matches 'Checkout view models must receive dependencies from their controllers.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$pledge_view_model" "$post_campaign_view_model"
reject_matches 'Pledge management view models must receive dependencies from their controllers.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$manage_pledge_view_model" "$cancel_pledge_view_model"
reject_matches 'ProjectPageViewModel must receive dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$project_page_view_model"
reject_matches 'DiscoveryFeature must receive its session lookup explicitly.' \
  'AppModel[.]shared|AppEnvironment[.]current[.]currentUser' "$discovery_feature"
reject_matches 'Discovery view models must receive feature dependencies from their controllers.' \
  'AppModel[.]shared' "$app_view/Views/Discovery/*ViewModel.swift" "$app_view/Views/DiscoveryFilters/*ViewModel.swift"
reject_matches 'Sign-in view models must receive Authentication from their controllers.' \
  'AppModel[.]shared' "$app_view/Views/Login/*ViewModel.swift" "$app_view/Views/LoginTout/*ViewModel.swift" \
  "$app_view/Views/FacebookConfirmation/*ViewModel.swift" "$app_view/Views/FacebookResetPasswordViewController/*ViewModel.swift"
reject_matches 'Password view models must receive their feature dependencies from their controllers.' \
  'AppModel[.]shared' "$app_view/Views/ChangePassword/*ViewModel.swift" \
  "$app_view/Views/CreatePassword/*ViewModel.swift" "$app_view/Views/ResetPassword/*ViewModel.swift"
reject_matches 'Backer Dashboard view models must receive Profile from their controllers.' \
  'AppModel[.]shared' "$app_view/Views/BackerDashboardPages/*ViewModel.swift" \
  "$app_view/Views/BackerDashboardProjects/*ViewModel.swift"
reject_matches 'Activity view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/Activities/*ViewModel.swift"
reject_matches 'Features must receive their application dependencies explicitly.' \
  'AppModel[.]shared' "$app_model/Features"
reject_matches 'View models must receive API and current-user dependencies from composition.' \
  'AppEnvironment[.]current[.](apiService|currentUser)([^[:alnum:]_]|$)' "$app_view/*ViewModel.swift"
reject_matches 'Application lifecycle signals belong at the AppModel boundary.' \
  'AppLifecycleFeature|appLifecycleFeature' "$app_view" "$app_model"
