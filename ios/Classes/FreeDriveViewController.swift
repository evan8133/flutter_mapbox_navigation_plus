//
//  FreeDriveViewController.swift
//  flutter_mapbox_navigation
//
//  Created by Emmanuel Oche on 5/25/23.
//

import UIKit
import MapboxNavigationUIKit
import MapboxNavigationCore
import MapboxMaps
import Combine

public class FreeDriveViewController : UIViewController {

    private var navigationMapView: NavigationMapView!
    private var mapboxNavigationProvider: MapboxNavigationProvider?
    private var mapboxNavigation: MapboxNavigation?
    private var subscriptions = Set<AnyCancellable>()

    public override func viewDidLoad() {
        super.viewDidLoad()

        setupNavigation()
        setupNavigationMapView()
    }
    
    private func setupNavigation() {
        let config = CoreConfig(locationSource: .live)
        mapboxNavigationProvider = MapboxNavigationProvider(coreConfig: config)
        mapboxNavigation = mapboxNavigationProvider?.mapboxNavigation
        
        // Start free drive mode
        mapboxNavigation?.tripSession().startFreeDrive()
    }

    private func setupNavigationMapView() {
        guard let navigation = mapboxNavigation else { return }
        
        navigationMapView = NavigationMapView(
            location: navigation.navigation().locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.navigation().routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            predictiveCacheManager: navigation.predictiveCacheManager
        )
        navigationMapView.frame = view.bounds
        navigationMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Configure camera to follow the user
        navigationMapView.navigationCamera.update(cameraState: .following)

        view.addSubview(navigationMapView)
    }

}