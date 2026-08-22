Pod::Spec.new do |s|
  s.name             = 'PaidUp'
  s.version          = '0.1.0'
  s.summary          = 'A lightweight StoreKit 2 entitlement layer for iOS (macOS only for tests).'
  s.description      = <<-DESC
    PaidUp answers "what is this user entitled to right now" from StoreKit 2,
    keeps that answer correct over time (renewals, refunds, revocations,
    Ask to Buy, grace periods, Family Sharing, upgrades), caches it to disk so
    the first frame is right, and exposes it as one value plus an AsyncStream —
    behind a four-call public API (init, isEntitled/entitlements, updates,
    purchase + restore). Optional provider hook merges your
    backend's view for cross-platform purchases.
  DESC
  s.homepage         = 'https://github.com/nimish-khandelwal/PaidUp'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Nimish Khandelwal' => 'nimishkhandelwal2503@gmail.com' }
  s.source           = { :git => 'https://github.com/nimish-khandelwal/PaidUp.git', :tag => "v#{s.version}" }

  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'
  s.swift_version          = '5.9'

  s.source_files   = 'Sources/PaidUpKit/**/*.swift'
  s.module_name    = 'PaidUpKit'
  s.frameworks     = 'Foundation', 'StoreKit'
  s.resource_bundles = { 'PaidUp' => ['Sources/PaidUpKit/Resources/PrivacyInfo.xcprivacy'] }
end
