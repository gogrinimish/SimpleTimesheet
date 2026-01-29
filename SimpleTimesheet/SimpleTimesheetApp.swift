import SwiftUI
#if canImport(SkipUI)
import SkipUI
#endif

@main
struct SimpleTimesheetApp: App {
    @StateObject private var viewModel = TimeTrackingViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    // Request notification permissions on first launch
                    Task {
                        _ = await viewModel.requestNotificationPermissions()
                    }
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == "simpletimesheet" else { return }
        
        switch url.host {
        case "stop":
            // Widget requested to stop timer - show stop dialog
            if viewModel.isTracking {
                viewModel.showStopDialogFromWidget = true
            }
        default:
            break
        }
    }
}
