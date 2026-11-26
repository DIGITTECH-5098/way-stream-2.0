import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@main
struct WayLinkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var client = StreamClient()
    @State private var profile = ConnectionProfile.loadAll().first ?? ConnectionProfile()
    @State private var isLive = false

    var body: some Scene {
        WindowGroup {
            RootView(profile: $profile, isLive: $isLive)
                .environmentObject(client)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Binding var profile: ConnectionProfile
    @Binding var isLive: Bool

    var body: some View {
        if isLive {
            StreamView(profile: $profile, isLive: $isLive)
                .transition(.opacity)
        } else {
            ConnectView(activeProfile: $profile, isLive: $isLive)
        }
    }
}
