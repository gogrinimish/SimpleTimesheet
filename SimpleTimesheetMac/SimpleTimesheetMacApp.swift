import SwiftUI
import AppKit

@main
struct SimpleTimesheetMacApp: App {
    @StateObject private var viewModel = TimeTrackingViewModel()
    @Environment(\.openSettings) private var openSettings
    
    var body: some Scene {
        // Settings window
        Settings {
            SettingsView(viewModel: viewModel)
        }
        
        // Menu bar extra
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label showing status
struct MenuBarLabel: View {
    @ObservedObject var viewModel: TimeTrackingViewModel
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.isTracking ? "clock.fill" : "clock")
            
            if viewModel.isTracking {
                Text(viewModel.currentElapsedFormatted)
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
            }
        }
    }
}
