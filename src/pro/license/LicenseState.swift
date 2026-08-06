enum LicenseState: Equatable {
    case trial(daysRemaining: Int)
    case pro
    case proExpired
    case trialExpired

    var isProAvailable: Bool {
        switch self {
        case .trial, .pro: return true
        case .proExpired, .trialExpired: return false
        }
    }

    var debugProfileLabel: String {
        switch self {
        case .trial: return "Trial"
        case .pro: return "Pro"
        case .proExpired, .trialExpired: return "Free"
        }
    }

    /// Raw tier tag sent as the `tier` appcast feed parameter for install-base
    /// analytics. Kept as the four distinct states (not the three-bucket
    /// `debugProfileLabel`) so the backend can split churned-pro from never-paid;
    /// the analytics view collapses proExpired+trialExpired into "free".
    var appcastTier: String {
        switch self {
        case .trial: return "trial"
        case .pro: return "pro"
        case .proExpired: return "proExpired"
        case .trialExpired: return "trialExpired"
        }
    }
}
