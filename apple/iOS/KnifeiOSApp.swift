import SwiftUI
import CloudKit
import UserNotifications
import KnifeKit

@main
struct KnifeiOSApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) var pushDelegate
    @StateObject private var store = MirrorStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(nil)
        }
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if !DemoData.enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await MirrorStore.shared.refresh()
            completionHandler(.newData)
        }
    }

    // show pushes while the app is foregrounded too
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct RootView: View {
    @EnvironmentObject var store: MirrorStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if store.iCloudAvailable {
                SessionListView()
            } else {
                VStack(spacing: 16) {
                    Text("Knife Terminal").font(.custom("Space Mono Bold", size: 13))
                    Text("Sign into iCloud in Settings to mirror your Mac's terminal.")
                        .font(.custom("Space Mono", size: 13))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 40)
                }
            }
        }
        .task { await store.startup() }
        .onChange(of: phase) { _, p in
            if p == .active { Task { await store.refresh() } }
        }
    }
}
