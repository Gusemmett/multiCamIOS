//
//  multiCamApp.swift
//  multiCam
//
//  Created by Angus Emmett on 8/23/25.
//

import SwiftUI
import UIKit

// AppDelegate used to lock the entire application to landscape orientations only
class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Allow both landscape directions, disallow portrait
        return [.landscapeLeft, .landscapeRight]
    }
}

@main
struct multiCamApp: App {
    // Attach the orientation-locking delegate
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var orientationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Orientation locked globally via AppDelegate; Scene modifier not needed.
    }
}

// Scene orientation lock extension removed (handled via AppDelegate)
