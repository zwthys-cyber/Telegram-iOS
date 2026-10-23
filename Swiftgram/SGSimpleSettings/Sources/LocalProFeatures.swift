// Build-time access to client-side features. Subscription status remains the
// value received from the service and is never rewritten by this policy.
public enum SGLocalFeatures {
    public static let proEnabled: Bool = {
        #if SG_LOCAL_PRO_FEATURES
        return true
        #else
        return false
        #endif
    }()

    public static func canUsePro(serverStatus: Int64) -> Bool {
        return proEnabled || serverStatus > 1
    }
}
