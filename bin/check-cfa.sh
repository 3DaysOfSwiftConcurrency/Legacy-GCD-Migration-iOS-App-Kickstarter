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
account_refresh="$app_model/Composition/AccountRefreshCoordinator.swift"
pledge_view_model="$app_view/Views/PledgeView/Controllers/PledgeViewModel.swift"
post_campaign_view_model="$app_view/Views/PledgeView/Controllers/PostCampaignCheckoutViewModel.swift"
manage_pledge_view_model="$app_view/Views/ManagePledge/Controllers/ManagePledgeViewModel.swift"
cancel_pledge_view_model="$app_view/Views/CancelPledge/Controller/CancelPledgeViewModel.swift"
project_page_view_model="$app_view/Views/ProjectPage/Controller/ProjectPageViewModel.swift"
discovery_feature="$app_model/Features/Discovery/DiscoveryFeature.swift"

test -f "$root_view_model"
test -f "$account_refresh"
test -f "$pledge_view_model"
test -f "$post_campaign_view_model"
test -f "$manage_pledge_view_model"
test -f "$cancel_pledge_view_model"
test -f "$project_page_view_model"
test -f "$discovery_feature"
reject_matches 'RootViewModel must receive its dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$root_view_model"
reject_matches 'The app delegate uses its composed owners directly.' \
  'AppDelegateViewModel' "$app_view" "$app_model"
reject_matches 'Account refresh receives its dependencies from composition.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$account_refresh"
reject_matches 'RemoteConfigurationService owns activation and publishes its outcome.' \
  'remoteConfig(Task|Version)|didUpdateRemoteConfigClient|remoteConfigClientConfigurationFailed|ksr_remoteConfigClientConfigured' \
  "$app_view/AppDelegate.swift"
reject_matches 'Settings link presentation receives its dependencies from composition.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$app_view/Navigation/SettingsLinkPresentation.swift"
reject_matches 'DeepLinkRouter receives platform dependencies from composition.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$app_view/Navigation/DeepLinkRouter.swift"
reject_matches 'Navigation owns email redirect delivery and release.' \
  'onFindRedirectUrl|foundRedirectUrl|resolveEmailRedirect|RedirectObservation|releaseEmailRedirect' \
  "$app_view/AppDelegate.swift"
reject_matches 'Checkout view models must receive dependencies from their controllers.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$pledge_view_model" "$post_campaign_view_model"
reject_matches 'Checkout view models use Authentication and Payments through their concrete features.' \
  '[.]sessionFeature|StripeIntentService|PaymentMethodsUseCase[(]|LoginSignupUseCase[(]' \
  "$pledge_view_model" "$post_campaign_view_model"
reject_matches 'Pledge owns checkout amount rules and API input construction.' \
  'struct (PledgeViewData|PledgeAmounts|PostCampaignAmounts)|calculatePledgeTotal[(]|CreateCheckoutInput[(]|CompleteOnSessionCheckoutInput|BackingInput[.]input[(]' \
  "$pledge_view_model" "$post_campaign_view_model"
reject_matches 'Pledge owns backing draft construction and payment retry eligibility.' \
  'personalization[.]backing[?][.]paymentSource|savedCreditCardId|incremental = .*pledgeOverTime' "$pledge_view_model"
reject_matches 'Checkout controllers use the same session identity as Pledge.' \
  'AppModel[.]shared[.]sessionFeature' "$app_view/Views/PledgeView/Controllers/PledgeViewController.swift" \
  "$app_view/Views/PledgeView/Controllers/PostCampaignCheckoutViewController.swift"
reject_matches 'Pledge CTA and shipping view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Shared Views/PledgeCTAContainerViewViewModel.swift" \
  "$app_view/Views/DesignSystem/Views/PledgeViewCTAContainerViewModel.swift" \
  "$app_view/Views/PledgeShippingLocation/*ViewModel.swift"
reject_matches 'Pledge management view models must receive dependencies from their controllers.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$manage_pledge_view_model" "$cancel_pledge_view_model" \
  "$app_view/Views/ManagePledge/Controllers/ManageViewPledgeRewardReceivedViewModel.swift"
reject_matches 'Pledge owns managed pledge eligibility and reward amounts.' \
  'ManagePledgeAlertAction[.]allCases|[.]isPledgeOverTimeAllowed|[.]status == [.]errored|[.]paymentIncrements[.]isEmpty|[.]addingCurrency[(]|Project[.]lens[.]personalization[.]backing' \
  "$manage_pledge_view_model"
reject_matches 'Pledge keeps the session collaborator private to its feature.' \
  'pledgeFeature[.]sessionFeature' "$app_view"
reject_matches 'Stored-card checkout uses Payments without environment or session access.' \
  'AppEnvironment[.]current|AppModel[.]shared|StripeIntentService|[.]sessionFeature' \
  "$app_view/Views/PledgePaymentMethods/Controller/PledgePaymentMethodsViewModel.swift"
reject_matches 'Payment Settings uses Payments without environment or session access.' \
  'AppModel[.]shared|AppEnvironment[.]current|StripeIntentService|[.]sessionFeature' \
  "$app_view/Views/PaymentMethods/Controller/PaymentMethodSettingsViewModel.swift"
reject_matches 'Payment Settings uses the session that requested the PaymentSheet.' \
  'AppModel[.]shared[.]sessionFeature' \
  "$app_view/Views/PaymentMethods/Controller/PaymentMethodSettingsViewController.swift"
reject_matches 'Payments owns checkout card eligibility, ranking, and selection.' \
  'availableCardTypes|stripeCardId|[.]sorted[(]|[.]isErroredPaymentMethod' \
  "$app_view/Views/PledgePaymentMethods/Controller/PledgePaymentMethodsViewModel.swift"
reject_matches 'The checkout PaymentSheet uses the configured Payments session.' \
  'AppModel[.]shared[.]sessionFeature' \
  "$app_view/Views/PledgePaymentMethods/Controller/PledgePaymentMethodsViewController.swift"
reject_matches 'Pledge summary and web view models must receive Pledge explicitly.' \
  'AppModel[.]shared' "$app_view/Views/ManagePledge/*ViewModel.swift" \
  "$app_view/Views/PledgePaymentMethods/*ViewModel.swift" "$app_view/Views/SurveyResponse/*ViewModel.swift"
reject_matches 'ProjectPageViewModel must receive dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$project_page_view_model"
reject_matches 'Project Page and update view models must receive their feature dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/ProjectPage/*ViewModel.swift" "$app_view/Views/Update/*ViewModel.swift"
reject_matches 'Project Page view models receive analytics, formatting, and story policy from composition.' \
  'AppEnvironment[.]current|featureProjectStoryRichTextEnabled\(' "$app_view/Views/ProjectPage/*ViewModel.swift"
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
reject_matches 'Find Friends view models must receive Friends explicitly.' \
  'AppModel[.]shared' "$app_view/Views/FindFriends/*ViewModel.swift"
reject_matches 'Discussion view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/Comments/*ViewModel.swift"
reject_matches 'Recommendation view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/CuratedProjects/*ViewModel.swift" "$app_view/Views/ThanksProjects/*ViewModel.swift"
reject_matches 'Settings view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/Settings*/*ViewModel.swift" "$app_view/Views/SelectCurrency/*ViewModel.swift"
reject_matches 'Two-factor authentication must receive Authentication explicitly.' \
  'AppModel[.]shared' "$app_view/Views/TwoFactorAuthentication/*ViewModel.swift"
reject_matches 'Project notification view models must receive Settings explicitly.' \
  'AppModel[.]shared' "$app_view/Views/ProjectNotifications/*ViewModel.swift"
reject_matches 'Report Project view models must receive Project Reporting explicitly.' \
  'AppModel[.]shared' "$app_view/Views/ReportProject/*ViewModel.swift"
reject_matches 'Rewards view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/RewardsCollection/*ViewModel.swift" \
  "$app_view/Views/RewardAddOnSelection/*ViewModel.swift"
reject_matches 'Pledged Projects view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/PledgedProjectsOverview/*ViewModel.swift"
reject_matches 'Search view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/Search/*ViewModel.swift"
reject_matches 'Messaging view models must receive their dependencies explicitly.' \
  'AppModel[.]shared' "$app_view/Views/MessageDialog/*ViewModel.swift" "$app_view/Views/MessageThreads/*ViewModel.swift" \
  "$app_view/Views/Messages/*ViewModel.swift" "$app_view/Views/SearchMessages/*ViewModel.swift"
reject_matches 'Features must receive their application dependencies explicitly.' \
  'AppModel[.]shared' "$app_model/Features"
reject_matches 'Settings must receive environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Settings/SettingsFeature.swift"
reject_matches 'Session must receive storage from composition.' \
  'AppEnvironment[.]' "$app_model/Features/Session/SessionFeature.swift"
reject_matches 'Discussion receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Discussion/DiscussionFeature.swift"
reject_matches 'Pledge receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Pledge/PledgeFeature.swift"
reject_matches 'Rewards receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Rewards/RewardsFeature.swift"
reject_matches 'Project Details receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/ProjectDetails"
reject_matches 'Project Details receives experiment policy from composition.' \
  'InstantPledgeButtonExperiment\(|featureProjectStoryRichTextEnabled\(' \
  "$app_model/Features/ProjectDetails/ProjectDetailsFeature.swift"
reject_matches 'Project Media and its watch view model receive environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/ProjectMedia/ProjectMediaFeature.swift" \
  "$app_view/Views/ProjectPage/Views/WatchProjectViewModel.swift"
reject_matches 'Video Feed receives analytics from composition.' \
  'AppEnvironment[.]current[.]ksrAnalytics' "$app_view/Views/VideoFeed/Controller/VideoFeedViewModel.swift"
reject_matches 'Video Feed sharing receives its dependencies from the presenter.' \
  'AppModel[.]shared|AppEnvironment[.]current' "$app_view/Views/VideoFeed/Social Sharing"
reject_matches 'View models must receive API and current-user dependencies from composition.' \
  'AppEnvironment[.]current[.](apiService|currentUser)([^[:alnum:]_]|$)' "$app_view/*ViewModel.swift"
reject_matches 'View models receive Apple Pay eligibility from composition.' \
  'AppEnvironment[.]current[.]applePayCapabilities' "$app_view/*ViewModel.swift"
reject_matches 'View models must receive application dependencies from composition.' \
  'AppModel[.]shared' "$app_view/*ViewModel.swift"
reject_matches 'Application lifecycle signals belong at the AppModel boundary.' \
  'AppLifecycleFeature|appLifecycleFeature' "$app_view" "$app_model"
