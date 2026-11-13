import Foundation

struct ActivityTrackingSettings: Codable, Equatable {
    var enabled = false
    var screenshotsEnabled = false
    var retentionDays = 400
    var screenshotRetentionDays = 7
    var excludedBundleIDs: [String] = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess"]
    var screenshotBundleIDs: [String] = []

    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, screenshotsEnabled, retentionDays, screenshotRetentionDays, excludedBundleIDs, screenshotBundleIDs }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        screenshotsEnabled = try c.decodeIfPresent(Bool.self, forKey: .screenshotsEnabled) ?? false
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 400
        screenshotRetentionDays = try c.decodeIfPresent(Int.self, forKey: .screenshotRetentionDays) ?? 7
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? excludedBundleIDs
        screenshotBundleIDs = try c.decodeIfPresent([String].self, forKey: .screenshotBundleIDs) ?? []
    }

    var resolvedRetentionDays: Int { [1, 7, 30, 90, 400].contains(retentionDays) ? retentionDays : 400 }
    var resolvedScreenshotRetentionDays: Int { [1, 7, 30, 90].contains(screenshotRetentionDays) ? screenshotRetentionDays : 7 }
}
