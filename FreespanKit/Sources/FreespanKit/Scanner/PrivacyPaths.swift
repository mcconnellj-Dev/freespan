import Foundation

extension DiskScanner {
    /// Locations macOS guards with per-app privacy prompts ("would like to access data from other apps",
    /// Photos, Mail, iCloud Drive, …). Without Full Disk Access, the app excludes these from a scan so the
    /// user isn't hit with a prompt per folder. With Full Disk Access none of them prompt, so pass no exclusions.
    /// Desktop, Documents and Downloads are deliberately not listed: they prompt once each and hold the files
    /// people most want to see.
    public static func privacyProtectedPaths(home: String = NSHomeDirectory()) -> [String] {
        let library = [
            "Containers", "Group Containers", "Mail", "Messages", "Safari", "Calendars", "Reminders",
            "Mobile Documents", "CloudStorage", "Application Support/AddressBook", "Application Support/CallHistoryDB",
            "Application Support/com.apple.TCC", "Application Support/MobileSync", "Application Support/Knowledge",
            "Application Support/FaceTime", "Application Support/com.apple.sharedfilelist", "HomeKit", "IdentityServices",
            "Cookies", "Suggestions", "Metadata/CoreSpotlight", "Biome", "Accounts", "PersonalizationPortrait",
            "Daemon Containers", "Autosave Information", "Sharing", "Trial", "Weather", "StatusKit", "DuetExpertCenter",
        ].map { "\(home)/Library/\($0)" }
        let media = [
            "Pictures/Photos Library.photoslibrary", "Music/Music", "Music/iTunes", "Movies/TV",
        ].map { "\(home)/\($0)" }
        return library + media + ["\(home)/.Trash"]
    }
}
