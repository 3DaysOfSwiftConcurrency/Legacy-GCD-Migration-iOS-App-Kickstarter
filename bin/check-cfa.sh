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
root_tabs="$app_view/Views/RootTabBar/RootTabBarViewController.swift"
account_refresh="$app_model/AppModel+AccountRefresh.swift"
pledge_view_model="$app_view/Views/PledgeView/Controllers/PledgeViewModel.swift"
post_campaign_view_model="$app_view/Views/PledgeView/Controllers/PostCampaignCheckoutViewModel.swift"
manage_pledge_view_model="$app_view/Views/ManagePledge/Controllers/ManagePledgeViewModel.swift"
cancel_pledge_view_model="$app_view/Views/CancelPledge/Controller/CancelPledgeViewModel.swift"
project_page_view_model="$app_view/Views/ProjectPage/Controller/ProjectPageViewModel.swift"
discovery_feature="$app_model/Features/Discovery/DiscoveryFeature.swift"
configuration_flags="$app_view/Views/FeatureFlagTools/Controller"
remote_configuration_flags="$app_view/Views/RemoteConfigFeatureFlagTools/Controller"
application_settings="$app_model/Features/Settings/SettingsFeature+ApplicationSettings.swift"
recommendations_feature="$app_model/Features/Recommendations/RecommendationsFeature.swift"
newsletter_cell_view_model="$app_view/Views/SettingsNewsletters/Views/Cells/SettingsNewslettersCellViewModel.swift"
thanks_view_model="$app_view/Views/ThanksProjects/Controller/ThanksViewModel.swift"
pledged_projects_feature="$app_model/Features/PledgedProjects"
pledged_projects_view="$app_view/Views/PledgedProjectsOverview"
pledge_feature="$app_model/Features/Pledge/PledgeFeature.swift"
pledge_manager_view_model="$app_view/Views/SurveyResponse/Controller/PledgeManagerWebViewModel.swift"

reject_matches 'Deep-link data resolution belongs to AppModel and its Features.' \
  'discussionFeature|discoveryFeature|activityFeature|messagingFeature|authenticationFeature|sessionFeature' \
  "$app_view/Navigation/DeepLinkRouter.swift"
reject_matches 'AppModel deep-link coordination returns data, not UIKit controllers.' \
  'import UIKit|UIViewController|UINavigationController' "$app_model/AppModel+DeepLinks.swift"
reject_matches 'ProjectMediaFeature owns video-feed availability policy.' \
  'featureVideoFeedEnabled|reachability|Reachability|connectivity' \
  "$app_view/Views/Search/Controller/SearchViewModel.swift" \
  "$app_view/Views/Discovery/Controller/DiscoveryPageViewModel.swift"
reject_matches 'Connectivity is composed privately behind ProjectMediaFeature.' \
  'connectivityService|reachability' "$app_model/Composition/Environment.swift" "$app_model/Composition/AppEnvironment.swift"
reject_matches 'AppModel exposes Features rather than the connectivity service.' \
  'connectivityService' "$app_model/AppModel.swift"
reject_matches 'SessionFeature owns device-to-account registration.' \
  'DevicePushRegistrationService|devicePushRegistrationService' "$app_view" "$app_model"
reject_matches 'OnboardingFeature owns application consent and push-authorization policy.' \
  'AppTrackingConsent|class PushAuthorization|let trackingConsent:|let pushAuthorization:' "$app_view" "$app_model"
reject_matches 'Flag tools read and change settings through their injected SettingsFeature.' \
  'AppEnvironment|AppModel[.]shared|[Uu]serDefaults|(featureEnabled|statsigFeatureEnabled)[[:space:]]*[(]' \
  "$configuration_flags/FeatureFlagToolsViewModel.swift" \
  "$remote_configuration_flags/RemoteConfigFeatureFlagToolsViewModel.swift"
reject_matches 'SettingsFeature owns flag persistence and configuration publication.' \
  'AppEnvironment|[Uu]serDefaults|DebugData|onUpdateConfig|onConfigUpdated|ksr_configUpdated' \
  "$configuration_flags/FeatureFlagToolsViewController.swift" \
  "$remote_configuration_flags/RemoteConfigFeatureFlagToolsViewController.swift"
reject_matches 'AppModel composes configuration services locally and stores only their owning Feature.' \
  'applicationConfigurationService|remoteConfigurationService|class[[:space:]]+(ApplicationConfigurationService|RemoteConfigurationService)|^  ((public|private|internal|fileprivate)[[:space:]]+)?(let|var)[[:space:]].*(ApplicationConfigurationService|RemoteConfigurationService)' \
  "$app_model/AppModel.swift"
test -f "$application_settings"
reject_matches 'Settings application-settings operations receive storage and clients from composition.' \
  'AppEnvironment|AppModel[.]shared|UserDefaults[.]standard|NotificationCenter[.]default' "$application_settings"
reject_matches 'Recommendations receives prompt storage, delay and transport from composition.' \
  'AppEnvironment|AppModel[.]shared' "$recommendations_feature"
reject_matches 'Newsletter settings policy and delay belong to SettingsFeature.' \
  'AppEnvironment|AppModel[.]shared' "$newsletter_cell_view_model"
reject_matches 'Thanks uses SettingsFeature for newsletter country policy and save delivery timing.' \
  'AppEnvironment[.]current[.](countryCode|apiDelayInterval)' "$thanks_view_model"
reject_matches 'Pledged Projects rollout policy belongs to PledgedProjectsFeature.' \
  'featurePledgedProjectsOverview(V2|V4)Enabled|featureEnabled[[:space:]]*[(]|remoteConfigClient' \
  "$pledged_projects_feature" "$pledged_projects_view"
reject_matches 'Pledged Projects Views receive presentation-ready policy from PPOViewModel.' \
  'RemoteConfigFeature|AppEnvironment[.]current[.](config|userDefaults|remoteConfigClient)' \
  "$pledged_projects_view/PPOView.swift" "$pledged_projects_view/PPOEmptyStateView.swift"
reject_matches 'PledgeFeature owns the Pledge Manager bypass decision.' \
  'featureBypassPledgeManagerDecisionPolicyEnabled|featureEnabled[[:space:]]*[(]|remoteConfigClient|AppEnvironment' \
  "$pledge_feature" "$pledge_manager_view_model"

test -f "$root_view_model"
test -f "$root_tabs"
test -f "$account_refresh"
test -f "$pledge_view_model"
test -f "$post_campaign_view_model"
test -f "$manage_pledge_view_model"
test -f "$cancel_pledge_view_model"
test -f "$project_page_view_model"
reject_matches 'Project Page observes related projects through ProjectDetailsFeature.' \
  'SimilarProjectsUseCase|DispatchQueue[.]main' "$project_page_view_model"
test -f "$discovery_feature"
reject_matches 'RootViewModel must receive its dependencies from the controller.' \
  'AppModel[.]shared|AppEnvironment[.]current|featureFloatingTabBarEnabled|profileFeature[.]sessionFeature' "$root_view_model"
reject_matches 'Root Tabs reads floating-tab policy through SettingsFeature.' \
  'featureFloatingTabBarEnabled|featureEnabled[[:space:]]*[(]|remoteConfigClient' "$root_view_model" "$root_tabs"
reject_matches 'Root Tabs owns and orders deferred UIKit presentation.' \
  'DispatchQueue[.]main' "$root_tabs"
reject_matches 'AppDelegate hands tab links to Root Tabs with their route delivery.' \
  'rootTabBarController[?][.]switchTo(Activities|Discovery|MessageThread|Search)' "$app_view/AppDelegate.swift"
reject_matches 'The app delegate uses its composed owners directly.' \
  'AppDelegateViewModel' "$app_view" "$app_model"
reject_matches 'AppModel coordinates account refresh through its concrete Features.' \
  'AccountRefreshCoordinator|ApplicationShortcutService' "$app_view" "$app_model"
reject_matches 'Native shortcut presentation stays in the View layer.' \
  'ShortcutItem|UIApplication' "$account_refresh"
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
reject_matches 'Checkout controllers use the payment presentation from their ViewModel.' \
  'AppModel[.]shared[.]sessionFeature|[.]sessionIdentity' "$app_view/Views/PledgeView/Controllers/PledgeViewController.swift" \
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
reject_matches 'Authentication receives platform dependencies from AppModel composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Authentication/AuthenticationFeature.swift" \
  "$app_view/Views/Login/Controller/LoginViewModel.swift"
reject_matches 'Messaging receives response policy from AppModel composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Messaging/MessagingFeature.swift"
reject_matches 'Friends receives response policy from AppModel composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Friends/FriendsFeature.swift"
reject_matches 'Profile receives response policy from AppModel composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Profile/ProfileFeature.swift"
reject_matches 'Pledge receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Pledge/PledgeFeature.swift"
reject_matches 'Rewards receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/Rewards/RewardsFeature.swift"
reject_matches 'Project Details receives environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/ProjectDetails"
reject_matches 'Project Details receives experiment policy from composition.' \
  'InstantPledgeButtonExperiment\(|featureProjectStoryRichTextEnabled\(' \
  "$app_model/Features/ProjectDetails/ProjectDetailsFeature.swift"
reject_matches 'ProjectDetailsFeature reads rich-text policy through SettingsFeature.' \
  'featureProjectStoryRichTextEnabled|statsigFeatureEnabled|statsigClient|includeRichText' \
  "$app_model/Features/ProjectDetails/ProjectDetailsFeature.swift" "$app_model/AppModel.swift"
reject_matches 'Project Media and its watch view model receive environment dependencies from composition.' \
  'AppEnvironment[.]current' "$app_model/Features/ProjectMedia/ProjectMediaFeature.swift" \
  "$app_view/Views/ProjectPage/Views/WatchProjectViewModel.swift"
reject_matches 'ProjectMediaFeature reads video-feed policy through SettingsFeature.' \
  'featureVideoFeedEnabled|statsigFeatureEnabled|statsigClient|isVideoFeedEnabled' \
  "$app_model/Features/ProjectMedia/ProjectMediaFeature.swift" "$app_model/AppModel.swift"
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
