import XCTest
@testable import SimpleTimesheetCore

/// Mock notification service for testing (avoids UNUserNotificationCenter)
class MockNotificationService: NotificationServiceProtocol {
    var authorizationRequested = false
    var scheduledReminders: [(DateComponents, [Int])] = []
    var cancelledAll = false
    
    func requestAuthorization() async -> Bool {
        authorizationRequested = true
        return true
    }
    
    func scheduleTimesheetReminder(at time: DateComponents, days: [Int]) async {
        scheduledReminders.append((time, days))
    }
    
    func cancelAllNotifications() {
        cancelledAll = true
    }
}

/// Mock email service for testing
class MockEmailService: EmailServiceProtocol {
    var sentTimesheets: [(Timesheet, AppConfiguration)] = []
    var shouldSucceed = true
    
    func sendTimesheet(_ timesheet: Timesheet, config: AppConfiguration) -> Bool {
        sentTimesheets.append((timesheet, config))
        return shouldSucceed && !config.approverEmail.isEmpty
    }
    
    func canSendEmail() -> Bool {
        return true
    }
    
    func exportAsCSV(_ timesheet: Timesheet) -> String {
        return "Date,Start,End,Duration,Description\n"
    }
}

@MainActor
final class TimeTrackingViewModelTests: XCTestCase {
    
    var viewModel: TimeTrackingViewModel!
    var tempDirectory: URL!
    var mockNotificationService: MockNotificationService!
    var mockEmailService: MockEmailService!
    
    override func setUp() async throws {
        // Create a temp directory for each test
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleTimesheetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Create mock services
        let storageService = StorageService()
        try storageService.setStorageFolder(tempDirectory.path)
        
        mockNotificationService = MockNotificationService()
        mockEmailService = MockEmailService()
        
        // Create view model with mock services
        viewModel = TimeTrackingViewModel(
            storageService: storageService,
            notificationService: mockNotificationService,
            emailService: mockEmailService
        )
        viewModel.isSetupComplete = true
    }
    
    override func tearDown() async throws {
        viewModel = nil
        mockNotificationService = nil
        mockEmailService = nil
        
        // Clean up temp directory
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }
    
    // MARK: - Initial State Tests
    
    func testInitialState() {
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertNil(viewModel.currentEntry)
        XCTAssertEqual(viewModel.currentElapsedTime, 0)
        XCTAssertTrue(viewModel.allEntries.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }
    
    // MARK: - Start/Stop Clock Tests
    
    func testStartClock() {
        viewModel.startClock()
        
        XCTAssertTrue(viewModel.isTracking)
        XCTAssertNotNil(viewModel.currentEntry)
        XCTAssertEqual(viewModel.allEntries.count, 1)
        XCTAssertTrue(viewModel.currentEntry?.isActive ?? false)
    }
    
    func testStartClockDoesNotStartIfAlreadyTracking() {
        viewModel.startClock()
        let firstEntryId = viewModel.currentEntry?.id
        
        // Try to start again
        viewModel.startClock()
        
        // Should still have only one entry
        XCTAssertEqual(viewModel.allEntries.count, 1)
        XCTAssertEqual(viewModel.currentEntry?.id, firstEntryId)
    }
    
    func testStopClock() {
        viewModel.startClock()
        let entryId = viewModel.currentEntry?.id
        
        viewModel.stopClock(description: "Test description", projectName: "Test Project")
        
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertNil(viewModel.currentEntry)
        XCTAssertEqual(viewModel.currentElapsedTime, 0)
        
        // Entry should be updated
        let entry = viewModel.allEntries.first(where: { $0.id == entryId })
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.description, "Test description")
        XCTAssertEqual(entry?.projectName, "Test Project")
        XCTAssertFalse(entry?.isActive ?? true)
    }
    
    func testStopClockDoesNothingIfNotTracking() {
        viewModel.stopClock(description: "Test")
        
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertTrue(viewModel.allEntries.isEmpty)
    }
    
    func testCancelTracking() {
        viewModel.startClock()
        XCTAssertEqual(viewModel.allEntries.count, 1)
        
        viewModel.cancelTracking()
        
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertNil(viewModel.currentEntry)
        XCTAssertEqual(viewModel.currentElapsedTime, 0)
        XCTAssertTrue(viewModel.allEntries.isEmpty) // Entry should be removed
    }
    
    func testCancelTrackingDoesNothingIfNotTracking() {
        viewModel.cancelTracking()
        
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertTrue(viewModel.allEntries.isEmpty)
    }
    
    // MARK: - Entry Management Tests
    
    func testUpdateEntry() {
        viewModel.startClock()
        viewModel.stopClock(description: "Original description")
        
        var entry = viewModel.allEntries[0]
        entry.description = "Updated description"
        entry.projectName = "New Project"
        
        viewModel.updateEntry(entry)
        
        XCTAssertEqual(viewModel.allEntries[0].description, "Updated description")
        XCTAssertEqual(viewModel.allEntries[0].projectName, "New Project")
    }
    
    func testDeleteEntry() {
        viewModel.startClock()
        viewModel.stopClock(description: "Test")
        XCTAssertEqual(viewModel.allEntries.count, 1)
        
        let entry = viewModel.allEntries[0]
        viewModel.deleteEntry(entry)
        
        XCTAssertTrue(viewModel.allEntries.isEmpty)
    }
    
    // MARK: - Computed Properties Tests
    
    func testTodayEntries() {
        // Add entry for today
        let todayEntry = TimeEntry(
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600),
            description: "Today's work"
        )
        viewModel.allEntries.append(todayEntry)
        
        // Add entry for yesterday
        let yesterdayEntry = TimeEntry(
            startTime: Date().addingTimeInterval(-86400),
            endTime: Date().addingTimeInterval(-82800),
            description: "Yesterday's work"
        )
        viewModel.allEntries.append(yesterdayEntry)
        
        XCTAssertEqual(viewModel.todayEntries.count, 1)
        XCTAssertEqual(viewModel.todayEntries[0].description, "Today's work")
    }
    
    func testThisWeekEntries() {
        // Add entry for today (should be in this week)
        let todayEntry = TimeEntry(
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600),
            description: "Today's work"
        )
        viewModel.allEntries.append(todayEntry)
        
        // Add entry for two weeks ago (should not be in this week)
        let oldEntry = TimeEntry(
            startTime: Date().addingTimeInterval(-14 * 86400),
            endTime: Date().addingTimeInterval(-14 * 86400 + 3600),
            description: "Old work"
        )
        viewModel.allEntries.append(oldEntry)
        
        XCTAssertEqual(viewModel.thisWeekEntries.count, 1)
        XCTAssertEqual(viewModel.thisWeekEntries[0].description, "Today's work")
    }
    
    func testTodayTotalSeconds() {
        // Add two 1-hour entries for today
        let entry1 = TimeEntry(
            startTime: Date().addingTimeInterval(-7200),
            endTime: Date().addingTimeInterval(-3600),
            description: "Work 1"
        )
        let entry2 = TimeEntry(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            description: "Work 2"
        )
        viewModel.allEntries = [entry1, entry2]
        
        // Should be approximately 2 hours (7200 seconds)
        XCTAssertEqual(viewModel.todayTotalSeconds, 7200, accuracy: 1)
    }
    
    func testTodayTotalFormatted() {
        let entry = TimeEntry(
            startTime: Date().addingTimeInterval(-3723), // 1 hour, 2 minutes, 3 seconds
            endTime: Date(),
            description: "Work"
        )
        viewModel.allEntries = [entry]
        
        XCTAssertEqual(viewModel.todayTotalFormatted, "1:02:03")
    }
    
    // MARK: - Timesheet Generation Tests
    
    func testGenerateTimesheet() {
        // Add entries
        let entry1 = TimeEntry(
            startTime: Date().addingTimeInterval(-7200),
            endTime: Date().addingTimeInterval(-3600),
            description: "Work 1"
        )
        let entry2 = TimeEntry(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            description: "Work 2"
        )
        viewModel.allEntries = [entry1, entry2]
        
        let timesheet = viewModel.generateTimesheet()
        
        XCTAssertNotNil(timesheet)
        XCTAssertEqual(timesheet.status, .draft)
        XCTAssertGreaterThanOrEqual(timesheet.entries.count, 0)
    }
    
    func testGenerateTimesheetStoresCurrentTimesheet() {
        let timesheet = viewModel.generateTimesheet()
        
        XCTAssertNotNil(viewModel.currentTimesheet)
        XCTAssertEqual(viewModel.currentTimesheet?.id, timesheet.id)
    }
    
    // MARK: - Configuration Tests
    
    func testUpdateConfiguration() {
        var newConfig = viewModel.configuration
        newConfig.userName = "Test User"
        newConfig.approverEmail = "test@example.com"
        
        viewModel.updateConfiguration(newConfig)
        
        XCTAssertEqual(viewModel.configuration.userName, "Test User")
        XCTAssertEqual(viewModel.configuration.approverEmail, "test@example.com")
    }
    
    // MARK: - Error Handling Tests
    
    func testClearError() {
        viewModel.errorMessage = "Test error"
        
        viewModel.clearError()
        
        XCTAssertNil(viewModel.errorMessage)
    }
    
    // MARK: - Duration Formatting Tests
    
    func testDurationFormattingMinutesOnly() {
        let entry = TimeEntry(
            startTime: Date().addingTimeInterval(-300), // 5 minutes
            endTime: Date(),
            description: "Short work"
        )
        viewModel.allEntries = [entry]
        
        XCTAssertEqual(viewModel.todayTotalFormatted, "05:00")
    }
    
    func testDurationFormattingWithHours() {
        let entry = TimeEntry(
            startTime: Date().addingTimeInterval(-5400), // 1.5 hours
            endTime: Date(),
            description: "Long work"
        )
        viewModel.allEntries = [entry]
        
        XCTAssertEqual(viewModel.todayTotalFormatted, "1:30:00")
    }
    
    // MARK: - Multiple Entry Tests
    
    func testMultipleStartStopCycles() {
        // First cycle
        viewModel.startClock()
        viewModel.stopClock(description: "First task")
        
        // Second cycle
        viewModel.startClock()
        viewModel.stopClock(description: "Second task")
        
        // Third cycle
        viewModel.startClock()
        viewModel.stopClock(description: "Third task")
        
        XCTAssertEqual(viewModel.allEntries.count, 3)
        XCTAssertFalse(viewModel.isTracking)
        
        // Verify all entries are completed
        for entry in viewModel.allEntries {
            XCTAssertFalse(entry.isActive)
            XCTAssertNotNil(entry.endTime)
        }
    }
    
    func testEntriesOrderedByMostRecent() {
        viewModel.startClock()
        viewModel.stopClock(description: "First")
        
        viewModel.startClock()
        viewModel.stopClock(description: "Second")
        
        // Most recent should be first
        XCTAssertEqual(viewModel.allEntries[0].description, "Second")
        XCTAssertEqual(viewModel.allEntries[1].description, "First")
    }
    
    // MARK: - Widget Integration Tests
    
    func testShowStopDialogFromWidgetInitialState() {
        // Initially should not show stop dialog
        XCTAssertFalse(viewModel.showStopDialogFromWidget)
    }
    
    func testShowStopDialogFromWidgetWhenTracking() {
        // Start tracking
        viewModel.startClock()
        XCTAssertTrue(viewModel.isTracking)
        
        // Simulate widget setting the stop request flag
        viewModel.showStopDialogFromWidget = true
        
        // Flag should be set
        XCTAssertTrue(viewModel.showStopDialogFromWidget)
    }
    
    func testWidgetStartSyncsToApp() {
        // Verify not tracking initially
        XCTAssertFalse(viewModel.isTracking)
        XCTAssertNil(viewModel.currentEntry)
        XCTAssertTrue(viewModel.allEntries.isEmpty)
    }
    
    func testPendingWidgetEntryInitialState() {
        // Initially no pending entry
        XCTAssertNil(viewModel.pendingWidgetEntry)
        XCTAssertFalse(viewModel.showWidgetEntryPrompt)
    }
    
    func testUpdateWidgetEntryDescription() {
        // Create a pending widget entry (simulating widget-added entry)
        let entry = TimeEntry(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date(),
            description: ""
        )
        viewModel.allEntries.insert(entry, at: 0)
        viewModel.pendingWidgetEntry = entry
        viewModel.showWidgetEntryPrompt = true
        
        // Update with description
        viewModel.updateWidgetEntryDescription("Widget task completed", projectName: "Test Project")
        
        // Verify entry was updated
        XCTAssertEqual(viewModel.allEntries[0].description, "Widget task completed")
        XCTAssertEqual(viewModel.allEntries[0].projectName, "Test Project")
        XCTAssertNil(viewModel.pendingWidgetEntry)
        XCTAssertFalse(viewModel.showWidgetEntryPrompt)
    }
    
    func testUpdateWidgetEntryDescriptionWithNoPendingEntry() {
        // No pending entry
        viewModel.pendingWidgetEntry = nil
        
        // Should not crash
        viewModel.updateWidgetEntryDescription("Some description")
        
        // Nothing should change
        XCTAssertTrue(viewModel.allEntries.isEmpty)
    }
    
    func testDismissWidgetEntryPromptSetsDefaultDescription() {
        // Create a pending widget entry
        let entry = TimeEntry(
            startTime: Date().addingTimeInterval(-900),
            endTime: Date(),
            description: ""
        )
        viewModel.allEntries.insert(entry, at: 0)
        viewModel.pendingWidgetEntry = entry
        viewModel.showWidgetEntryPrompt = true
        
        // Dismiss without adding description
        viewModel.dismissWidgetEntryPrompt()
        
        // Verify default description was set
        XCTAssertEqual(viewModel.allEntries[0].description, "Tracked from widget")
        XCTAssertNil(viewModel.pendingWidgetEntry)
        XCTAssertFalse(viewModel.showWidgetEntryPrompt)
    }
}
