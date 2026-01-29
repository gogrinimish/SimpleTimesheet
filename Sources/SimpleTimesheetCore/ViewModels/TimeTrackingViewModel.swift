import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(SkipFoundation)
import SkipFoundation
#endif

/// Main ViewModel for time tracking functionality
/// Observable and compatible with Skip for Android transpilation
@MainActor
public class TimeTrackingViewModel: ObservableObject {
    
    // MARK: - Published State
    
    /// Current active time entry (nil if not tracking)
    @Published public var currentEntry: TimeEntry?
    
    /// All time entries
    @Published public var allEntries: [TimeEntry] = []
    
    /// Current app configuration
    @Published public var configuration: AppConfiguration
    
    /// Whether the app is currently tracking time
    @Published public var isTracking: Bool = false
    
    /// Error message to display
    @Published public var errorMessage: String?
    
    /// Whether setup is complete
    @Published public var isSetupComplete: Bool = false
    
    /// Current timesheet being previewed/edited
    @Published public var currentTimesheet: Timesheet?
    
    /// Loading state
    @Published public var isLoading: Bool = false
    
    /// Entry that was added from widget and needs a description
    @Published public var pendingWidgetEntry: TimeEntry?
    
    /// Whether to show the widget entry description prompt
    @Published public var showWidgetEntryPrompt: Bool = false
    
    /// Whether widget requested to stop the timer (shows stop dialog)
    @Published public var showStopDialogFromWidget: Bool = false
    
    // MARK: - Computed Properties
    
    /// Entries for today
    public var todayEntries: [TimeEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return allEntries.filter { calendar.isDate($0.startTime, inSameDayAs: today) }
    }
    
    /// Entries for this week
    public var thisWeekEntries: [TimeEntry] {
        let calendar = Calendar.current
        let now = Date()
        guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else {
            return []
        }
        return allEntries.filter { $0.startTime >= weekStart }
    }
    
    /// Total time tracked today in seconds
    public var todayTotalSeconds: TimeInterval {
        todayEntries.totalDuration
    }
    
    /// Formatted total for today
    public var todayTotalFormatted: String {
        formatDuration(todayTotalSeconds)
    }
    
    /// Total time tracked this week
    public var thisWeekTotalFormatted: String {
        formatDuration(thisWeekEntries.totalDuration)
    }
    
    /// Current entry elapsed time (updates with timer)
    @Published public var currentElapsedTime: TimeInterval = 0
    
    /// Formatted elapsed time for current entry
    public var currentElapsedFormatted: String {
        formatDuration(currentElapsedTime)
    }
    
    // MARK: - Services
    
    private let storageService: StorageServiceProtocol
    private let notificationService: NotificationServiceProtocol
    private let emailService: EmailServiceProtocol
    
    // MARK: - Widget Support
    
    /// App Group identifier for sharing data with widgets
    private static let appGroupIdentifier = "group.com.simpletimesheet.shared"
    
    /// Shared UserDefaults for widget data
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }
    
    // MARK: - Private
    
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    public init(
        storageService: StorageServiceProtocol = StorageService.shared,
        notificationService: NotificationServiceProtocol = NotificationService.shared,
        emailService: EmailServiceProtocol = EmailService.shared
    ) {
        self.storageService = storageService
        self.notificationService = notificationService
        self.emailService = emailService
        self.configuration = AppConfiguration()
        
        // Try to load from default path first
        Task {
            await initializeStorage()
        }
    }
    
    // MARK: - Initialization Methods
    
    /// Initialize storage with saved or default path
    private func initializeStorage() async {
        isLoading = true
        defer { isLoading = false }
        
        // Try to load from UserDefaults first to get the storage path
        if let savedPath = UserDefaults.standard.string(forKey: "storageFolderPath"),
           storageService.isValidStorageFolder(savedPath) {
            do {
                try storageService.setStorageFolder(savedPath)
                try await loadAllData()
                isSetupComplete = true
            } catch {
                errorMessage = "Failed to load data: \(error.localizedDescription)"
            }
        }
    }
    
    /// Set up storage with a specific folder path
    public func setupStorage(path: String) async throws {
        guard storageService.isValidStorageFolder(path) else {
            throw StorageError.invalidPath
        }
        
        try storageService.setStorageFolder(path)
        
        // Save the path for next launch
        UserDefaults.standard.set(path, forKey: "storageFolderPath")
        
        // Update configuration
        configuration.storageFolder = path
        try storageService.saveConfiguration(configuration)
        
        // Load existing data if any
        try await loadAllData()
        
        isSetupComplete = true
    }
    
    /// Load all data from storage
    private func loadAllData() async throws {
        configuration = try storageService.loadConfiguration()
        allEntries = try storageService.loadTimeEntries()
        
        // Check for any active entry
        if let activeEntry = allEntries.first(where: { $0.isActive }) {
            currentEntry = activeEntry
            isTracking = true
            startTimer()
        }
        
        // Sync with widget state (widget may have started/stopped tracking)
        syncFromWidget()
        
        // Schedule notifications
        await scheduleNotifications()
        
        // Sync data to widgets
        syncWidgetData()
    }
    
    /// Sync state from widget (called when app becomes active)
    public func syncFromWidget() {
        #if os(iOS)
        guard let defaults = sharedDefaults else { return }
        
        let widgetIsTracking = defaults.bool(forKey: "isTracking")
        let widgetStartTime = defaults.object(forKey: "trackingStartTime") as? Date
        
        // If widget started tracking but we're not, start tracking
        if widgetIsTracking && !isTracking, let startTime = widgetStartTime {
            // Check if we already have an entry with this start time
            let existingEntry = allEntries.first { 
                abs($0.startTime.timeIntervalSince(startTime)) < 1 
            }
            
            if existingEntry == nil {
                // Create new entry from widget start
                let entry = TimeEntry(startTime: startTime)
                currentEntry = entry
                isTracking = true
                allEntries.insert(entry, at: 0)
                saveEntries()
                startTimer()
            } else if let existing = existingEntry, existing.isActive {
                // Resume tracking the existing entry
                currentEntry = existing
                isTracking = true
                startTimer()
            }
        }
        
        // If we're tracking but widget shows not tracking, sync to widget
        if isTracking && !widgetIsTracking {
            syncWidgetData()
        }
        #endif
    }
    
    /// Update the pending widget entry with a description
    public func updateWidgetEntryDescription(_ description: String, projectName: String? = nil) {
        guard var entry = pendingWidgetEntry else { return }
        
        entry.description = description
        entry.projectName = projectName
        
        // Update in entries list
        if let index = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries[index] = entry
            saveEntries()
        }
        
        pendingWidgetEntry = nil
        showWidgetEntryPrompt = false
    }
    
    /// Dismiss the widget entry prompt without adding description
    public func dismissWidgetEntryPrompt() {
        // Set a default description
        if var entry = pendingWidgetEntry {
            entry.description = "Tracked from widget"
            if let index = allEntries.firstIndex(where: { $0.id == entry.id }) {
                allEntries[index] = entry
                saveEntries()
            }
        }
        
        pendingWidgetEntry = nil
        showWidgetEntryPrompt = false
    }
    
    // MARK: - Time Tracking Actions
    
    /// Start tracking time
    public func startClock() {
        guard !isTracking else { return }
        
        let entry = TimeEntry(startTime: Date())
        currentEntry = entry
        isTracking = true
        
        // Add to entries and save
        allEntries.insert(entry, at: 0)
        saveEntries()
        
        startTimer()
    }
    
    /// Stop tracking time with a description
    public func stopClock(description: String, projectName: String? = nil) {
        guard isTracking, var entry = currentEntry else { return }
        
        stopTimer()
        
        entry.stop(withDescription: description)
        entry.projectName = projectName
        
        // Update in entries list
        if let index = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries[index] = entry
        }
        
        currentEntry = nil
        isTracking = false
        currentElapsedTime = 0
        
        saveEntries()
    }
    
    /// Cancel current tracking without saving
    public func cancelTracking() {
        guard isTracking, let entry = currentEntry else { return }
        
        stopTimer()
        
        // Remove the entry
        allEntries.removeAll { $0.id == entry.id }
        
        currentEntry = nil
        isTracking = false
        currentElapsedTime = 0
        
        saveEntries()
    }
    
    /// Update an existing entry
    public func updateEntry(_ entry: TimeEntry) {
        if let index = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries[index] = entry
            saveEntries()
        }
    }
    
    /// Delete an entry
    public func deleteEntry(_ entry: TimeEntry) {
        allEntries.removeAll { $0.id == entry.id }
        saveEntries()
    }
    
    // MARK: - Timer Management
    
    private func startTimer() {
        timer?.invalidate()
        updateElapsedTime()
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateElapsedTime()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateElapsedTime() {
        guard let entry = currentEntry else {
            currentElapsedTime = 0
            return
        }
        currentElapsedTime = Date().timeIntervalSince(entry.startTime)
    }
    
    // MARK: - Timesheet Actions
    
    /// Generate a timesheet for the current period
    public func generateTimesheet() -> Timesheet {
        let calendar = Calendar.current
        let now = Date()
        
        let periodStart: Date
        let periodEnd: Date
        
        switch configuration.timesheetPeriod {
        case .weekly:
            periodStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            periodEnd = calendar.date(byAdding: .day, value: 6, to: periodStart)!
        case .biweekly:
            let weekOfYear = calendar.component(.weekOfYear, from: now)
            let adjustedWeek = weekOfYear - (weekOfYear % 2)
            var components = calendar.dateComponents([.yearForWeekOfYear], from: now)
            components.weekOfYear = adjustedWeek
            periodStart = calendar.date(from: components)!
            periodEnd = calendar.date(byAdding: .day, value: 13, to: periodStart)!
        case .monthly:
            periodStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            periodEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: periodStart)!
        }
        
        let entries = allEntries.entries(from: periodStart, to: periodEnd)
        
        let timesheet = Timesheet(
            periodStart: periodStart,
            periodEnd: periodEnd,
            entries: entries
        )
        
        currentTimesheet = timesheet
        return timesheet
    }
    
    /// Send the current timesheet via email
    public func sendTimesheet() -> Bool {
        guard let timesheet = currentTimesheet else {
            errorMessage = "No timesheet to send"
            return false
        }
        
        let errors = configuration.validate()
        if !errors.isEmpty {
            errorMessage = errors.joined(separator: "\n")
            return false
        }
        
        // Update timesheet status
        var updatedTimesheet = timesheet
        updatedTimesheet.status = .submitted
        updatedTimesheet.submittedAt = Date()
        
        // Save timesheet
        do {
            try storageService.saveTimesheet(updatedTimesheet)
        } catch {
            errorMessage = "Failed to save timesheet: \(error.localizedDescription)"
            return false
        }
        
        // Send email
        let success = emailService.sendTimesheet(updatedTimesheet, config: configuration)
        
        if success {
            currentTimesheet = updatedTimesheet
        } else {
            errorMessage = "Failed to open email client"
        }
        
        return success
    }
    
    /// Export timesheet as CSV
    public func exportTimesheetAsCSV() -> String? {
        guard let timesheet = currentTimesheet else { return nil }
        return emailService.exportAsCSV(timesheet)
    }
    
    // MARK: - Configuration
    
    /// Update configuration
    public func updateConfiguration(_ newConfig: AppConfiguration) {
        configuration = newConfig
        
        do {
            try storageService.saveConfiguration(configuration)
        } catch {
            errorMessage = "Failed to save configuration: \(error.localizedDescription)"
        }
        
        // Reschedule notifications
        Task {
            await scheduleNotifications()
        }
    }
    
    // MARK: - Notifications
    
    /// Request notification permissions
    public func requestNotificationPermissions() async -> Bool {
        return await notificationService.requestAuthorization()
    }
    
    /// Schedule timesheet reminder notifications
    private func scheduleNotifications() async {
        guard let timeComponents = configuration.notificationTimeComponents else { return }
        
        await notificationService.scheduleTimesheetReminder(
            at: timeComponents,
            days: configuration.notificationDays
        )
    }
    
    // MARK: - Helpers
    
    /// Format a duration in seconds to a human-readable string
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    /// Save entries to storage
    private func saveEntries() {
        do {
            try storageService.saveTimeEntries(allEntries)
            syncWidgetData()
        } catch {
            errorMessage = "Failed to save entries: \(error.localizedDescription)"
        }
    }
    
    /// Clear error message
    public func clearError() {
        errorMessage = nil
    }
    
    // MARK: - Widget Data Sync
    
    /// Sync current tracking state to widgets via shared UserDefaults
    private func syncWidgetData() {
        #if os(iOS)
        guard let defaults = sharedDefaults else { return }
        
        // Tracking state
        defaults.set(isTracking, forKey: "isTracking")
        defaults.set(currentEntry?.startTime, forKey: "trackingStartTime")
        
        // Today's totals
        defaults.set(todayTotalSeconds, forKey: "todayTotal")
        defaults.set(todayEntries.count, forKey: "todayEntryCount")
        
        // Week totals
        defaults.set(thisWeekEntries.totalDuration, forKey: "weekTotal")
        
        // Trigger widget refresh
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #endif
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension TimeTrackingViewModel {
    /// Create a preview instance with sample data
    public static var preview: TimeTrackingViewModel {
        let vm = TimeTrackingViewModel()
        vm.isSetupComplete = true
        vm.configuration = AppConfiguration(
            storageFolder: "/tmp/SimpleTimesheet",
            approverEmail: "manager@example.com",
            userName: "John Doe"
        )
        
        // Add sample entries
        let calendar = Calendar.current
        let now = Date()
        
        vm.allEntries = [
            TimeEntry(
                startTime: calendar.date(byAdding: .hour, value: -2, to: now)!,
                endTime: calendar.date(byAdding: .hour, value: -1, to: now)!,
                description: "Working on feature implementation",
                projectName: "Project Alpha"
            ),
            TimeEntry(
                startTime: calendar.date(byAdding: .hour, value: -4, to: now)!,
                endTime: calendar.date(byAdding: .hour, value: -2, to: now)!,
                description: "Code review and documentation",
                projectName: "Project Alpha"
            ),
            TimeEntry(
                startTime: calendar.date(byAdding: .day, value: -1, to: now)!,
                endTime: calendar.date(byAdding: .hour, value: -20, to: now)!,
                description: "Team meeting",
                projectName: "General"
            )
        ]
        
        return vm
    }
}
#endif
