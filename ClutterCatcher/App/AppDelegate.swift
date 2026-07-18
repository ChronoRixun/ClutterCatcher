import CloudKit
import UIKit

/// SwiftUI has no native hook for CloudKit share acceptance, so the classic
/// delegate chain carries it (plan §3.3, M3-E): the app delegate names a
/// scene-delegate class, and that class receives the accepted share's
/// metadata — both for a running app and for a cold launch straight from an
/// invite link. The metadata is handed to `ShareAcceptanceModel`, which owns
/// everything after that.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from an invite link: the metadata rides in the connection
    /// options instead of the acceptance callback.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            ShareAcceptanceModel.shared.receive(metadata)
        }
    }

    /// Warm acceptance: the app was already running when the user tapped the
    /// invite.
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        ShareAcceptanceModel.shared.receive(cloudKitShareMetadata)
    }
}
