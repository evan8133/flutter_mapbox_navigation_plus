import Flutter
import UIKit
import MapboxMaps
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit
import Combine

public class FlutterMapboxNavigationView : NavigationFactory, FlutterPlatformView
{
    let frame: CGRect
    let viewId: Int64

    let messenger: FlutterBinaryMessenger
    let channel: FlutterMethodChannel
    let eventChannel: FlutterEventChannel

    var navigationMapView: NavigationMapView!
    var arguments: NSDictionary?

    var _navigationRoutes: NavigationRoutes?
    var selectedRouteIndex = 0
    var routeOptions: NavigationRouteOptions?

    var _mapInitialized = false;
    var locationManager = CLLocationManager()
    
    private var subscriptions = Set<AnyCancellable>()

    init(messenger: FlutterBinaryMessenger, frame: CGRect, viewId: Int64, args: Any?)
    {
        self.frame = frame
        self.viewId = viewId
        self.arguments = args as! NSDictionary?

        self.messenger = messenger
        self.channel = FlutterMethodChannel(name: "flutter_mapbox_navigation/\(viewId)", binaryMessenger: messenger)
        self.eventChannel = FlutterEventChannel(name: "flutter_mapbox_navigation/\(viewId)/events", binaryMessenger: messenger)

        super.init()

        self.eventChannel.setStreamHandler(self)

        self.channel.setMethodCallHandler { [weak self](call, result) in

            guard let strongSelf = self else { return }

            let arguments = call.arguments as? NSDictionary

            if(call.method == "getPlatformVersion")
            {
                result("iOS " + UIDevice.current.systemVersion)
            }
            else if(call.method == "buildRoute")
            {
                strongSelf.buildRoute(arguments: arguments, flutterResult: result)
            }
            else if(call.method == "clearRoute")
            {
                strongSelf.clearRoute(arguments: arguments, result: result)
            }
            else if(call.method == "getDistanceRemaining")
            {
                result(strongSelf._distanceRemaining)
            }
            else if(call.method == "getDurationRemaining")
            {
                result(strongSelf._durationRemaining)
            }
            else if(call.method == "finishNavigation")
            {
                strongSelf.endNavigation(result: result)
            }
            else if(call.method == "startFreeDrive")
            {
                strongSelf.startEmbeddedFreeDrive(arguments: arguments, result: result)
            }
            else if(call.method == "startNavigation")
            {
                strongSelf.startEmbeddedNavigation(arguments: arguments, result: result)
            }
            else if(call.method == "reCenter"){
                //used to recenter map from user action during navigation
                strongSelf.navigationMapView.navigationCamera.update(cameraState: .following)
            }
            else
            {
                result("method is not implemented");
            }

        }
    }

    public func view() -> UIView
    {
        if(_mapInitialized)
        {
            return navigationMapView
        }

        setupMapView()

        return navigationMapView
    }

    
    private func setupMapView()
    {
        // Initialize MapboxNavigationProvider if needed
        if mapboxNavigationProvider == nil {
            let config = CoreConfig(
                locationSource: _simulateRoute ? .simulation(initialLocation: nil) : .live
            )
            mapboxNavigationProvider = MapboxNavigationProvider(coreConfig: config)
            mapboxNavigation = mapboxNavigationProvider?.mapboxNavigation
        }
        
        guard let navigation = mapboxNavigation else { return }
        
        navigationMapView = NavigationMapView(
            location: navigation.navigation().locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.navigation().routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            predictiveCacheManager: navigation.predictiveCacheManager
        )
        navigationMapView.frame = frame
        navigationMapView.delegate = self

        if(self.arguments != nil)
        {
           
            parseFlutterArguments(arguments: arguments)
            
            if(_mapStyleUrlDay != nil)
            {
                navigationMapView.mapView.mapboxMap.loadStyle(StyleURI(url: URL(string: _mapStyleUrlDay!)!)!)
            }

            var currentLocation: CLLocation!

            locationManager.requestWhenInUseAuthorization()

            if(CLLocationManager.authorizationStatus() == .authorizedWhenInUse ||
                CLLocationManager.authorizationStatus() == .authorizedAlways) {
                currentLocation = locationManager.location

            }

            let initialLatitude = arguments?["initialLatitude"] as? Double ?? currentLocation?.coordinate.latitude
            let initialLongitude = arguments?["initialLongitude"] as? Double ?? currentLocation?.coordinate.longitude
            if(initialLatitude != nil && initialLongitude != nil)
            {
                moveCameraToCoordinates(latitude: initialLatitude!, longitude: initialLongitude!)
            }

        }

        if _longPressDestinationEnabled
        {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            gesture.delegate = self
            navigationMapView?.addGestureRecognizer(gesture)
        }
        
        if _enableOnMapTapCallback {
            let onTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            onTapGesture.numberOfTapsRequired = 1
            onTapGesture.delegate = self
            navigationMapView?.addGestureRecognizer(onTapGesture)
        }
        
        _mapInitialized = true
    }

    func clearRoute(arguments: NSDictionary?, result: @escaping FlutterResult)
    {
        if _navigationRoutes == nil
        {
            return
        }
        
        mapboxNavigation?.tripSession().startFreeDrive()
        navigationMapView.removeRoutes()
        _navigationRoutes = nil
        sendEvent(eventType: MapBoxEventType.navigation_cancelled)
    }

    func buildRoute(arguments: NSDictionary?, flutterResult: @escaping FlutterResult)
    {
        _wayPoints.removeAll()
        isEmbeddedNavigation = true
        sendEvent(eventType: MapBoxEventType.route_building)

        guard let oWayPoints = arguments?["wayPoints"] as? NSDictionary else {return}

        var locations = [Location]()

        for item in oWayPoints as NSDictionary
        {
            let point = item.value as! NSDictionary
            guard let oName = point["Name"] as? String else {return}
            guard let oLatitude = point["Latitude"] as? Double else {return}
            guard let oLongitude = point["Longitude"] as? Double else {return}
            let oIsSilent = point["IsSilent"] as? Bool ?? false
            let order = point["Order"] as? Int
            let location = Location(name: oName, latitude: oLatitude, longitude: oLongitude, order: order,isSilent: oIsSilent)
            locations.append(location)
        }

        if(!_isOptimized)
        {
            //waypoints must be in the right order
            locations.sort(by: {$0.order ?? 0 < $1.order ?? 0})
        }


        for loc in locations
        {
            let location = Waypoint(coordinate: CLLocationCoordinate2D(latitude: loc.latitude!, longitude: loc.longitude!),
                                    coordinateAccuracy: -1, name: loc.name)
            location.separatesLegs = !loc.isSilent
            _wayPoints.append(location)
        }

        parseFlutterArguments(arguments: arguments)
        
        if(_wayPoints.count > 3 && arguments?["mode"] == nil)
        {
            _navigationMode = "driving"
        }

        var mode: ProfileIdentifier = .automobileAvoidingTraffic

        if (_navigationMode == "cycling")
        {
            mode = .cycling
        }
        else if(_navigationMode == "driving")
        {
            mode = .automobile
        }
        else if(_navigationMode == "walking")
        {
            mode = .walking
        }

        let routeOptions = NavigationRouteOptions(waypoints: _wayPoints, profileIdentifier: mode)

        if (_allowsUTurnAtWayPoints != nil)
        {
            routeOptions.allowsUTurnAtWaypoint = _allowsUTurnAtWayPoints!
        }

        routeOptions.distanceMeasurementSystem = _voiceUnits == "imperial" ? .imperial : .metric
        routeOptions.locale = Locale(identifier: _language)
        routeOptions.includesAlternativeRoutes = _alternatives
        self.routeOptions = routeOptions

        guard let navigation = mapboxNavigation else {
            flutterResult(false)
            return
        }
        
        let routingProvider = navigation.routingProvider()
        
        Task {
            do {
                let routes = try await routingProvider.calculateRoutes(options: routeOptions).value
                
                await MainActor.run {
                    self._navigationRoutes = routes
                    self.sendEvent(eventType: MapBoxEventType.route_built, data: self.encodeNavigationRoutes(routes: routes))
                    self.navigationMapView?.showcase(routes, animated: true)
                    flutterResult(true)
                }
            } catch {
                await MainActor.run {
                    flutterResult(false)
                    self.sendEvent(eventType: MapBoxEventType.route_build_failed)
                }
            }
        }
    }

    func startEmbeddedFreeDrive(arguments: NSDictionary?, result: @escaping FlutterResult) {
        guard let navigation = mapboxNavigation else {
            result(false)
            return
        }
        
        navigation.tripSession().startFreeDrive()

        navigationMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        // Configure camera to follow the user
        navigationMapView.navigationCamera.update(cameraState: .following)
        
        result(true)
    }

    func startEmbeddedNavigation(arguments: NSDictionary?, result: @escaping FlutterResult) {
        guard let routes = self._navigationRoutes else { return }
        guard let navigation = mapboxNavigation else { return }
        
        // Remove previous navigation view and controller if any
        if(_navigationViewController?.view != nil){
            _navigationViewController!.view.removeFromSuperview()
            _navigationViewController?.removeFromParent()
        }

        _navigationViewController = NavigationViewController(
            navigationRoutes: routes,
            navigationOptions: NavigationOptions(
                mapboxNavigation: navigation,
                voiceController: navigation.voiceController(),
                eventsManager: navigation.eventsManager()
            )
        )
        _navigationViewController!.delegate = self

        let flutterViewController = UIApplication.shared.delegate?.window?!.rootViewController as! FlutterViewController
        flutterViewController.addChild(_navigationViewController!)

        self.navigationMapView.addSubview(_navigationViewController!.view)
        _navigationViewController!.view.translatesAutoresizingMaskIntoConstraints = false
        constraintsWithPaddingBetween(holderView: self.navigationMapView, topView: _navigationViewController!.view, padding: 0.0)
        flutterViewController.didMove(toParent: flutterViewController)
        
        // Start the navigation
        navigation.tripSession().startActiveGuidance(with: routes, startLegIndex: 0)
        
        // Subscribe to progress updates
        navigation.navigation()
            .routeProgress
            .compactMap { $0?.routeProgress }
            .sink { [weak self] progress in
                guard let self = self else { return }
                self._distanceRemaining = progress.distanceRemaining
                self._durationRemaining = progress.durationRemaining
                self.sendEvent(eventType: MapBoxEventType.navigation_running)
                
                if self._eventSink != nil {
                    let jsonEncoder = JSONEncoder()
                    let progressEvent = MapBoxRouteProgressEvent(progress: progress)
                    if let progressEventJsonData = try? jsonEncoder.encode(progressEvent),
                       let progressEventJson = String(data: progressEventJsonData, encoding: .ascii) {
                        self._eventSink!(progressEventJson)
                    }
                }
            }
            .store(in: &subscriptions)
        
        result(true)

    }

    func constraintsWithPaddingBetween(holderView: UIView, topView: UIView, padding: CGFloat) {
        guard holderView.subviews.contains(topView) else {
            return
        }
        topView.translatesAutoresizingMaskIntoConstraints = false
        let pinTop = NSLayoutConstraint(item: topView, attribute: .top, relatedBy: .equal,
                                        toItem: holderView, attribute: .top, multiplier: 1.0, constant: padding)
        let pinBottom = NSLayoutConstraint(item: topView, attribute: .bottom, relatedBy: .equal,
                                           toItem: holderView, attribute: .bottom, multiplier: 1.0, constant: padding)
        let pinLeft = NSLayoutConstraint(item: topView, attribute: .left, relatedBy: .equal,
                                         toItem: holderView, attribute: .left, multiplier: 1.0, constant: padding)
        let pinRight = NSLayoutConstraint(item: topView, attribute: .right, relatedBy: .equal,
                                          toItem: holderView, attribute: .right, multiplier: 1.0, constant: padding)
        holderView.addConstraints([pinTop, pinBottom, pinLeft, pinRight])
    }

    func moveCameraToCoordinates(latitude: Double, longitude: Double) {
        let cameraOptions = CameraOptions(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            padding: .zero,
            zoom: _zoom,
            bearing: _bearing,
            pitch: 15
        )
        navigationMapView.mapView.camera.ease(to: cameraOptions, duration: 1.0)
    }

    func moveCameraToCenter()
    {
        var duration = 5.0
        if(!_animateBuildRoute)
        {
            duration = 0.0
        }

        let cameraOptions = CameraOptions(
            zoom: 13.0,
            pitch: 15
        )
        navigationMapView.mapView.camera.ease(to: cameraOptions, duration: duration)
    }

}

extension FlutterMapboxNavigationView : NavigationMapViewDelegate {

    public func navigationMapView(_ mapView: NavigationMapView, didSelect alternativeRoute: AlternativeRoute) {
        Task {
            guard let selectedRoutes = await self._navigationRoutes?.selecting(alternativeRoute: alternativeRoute) else { return }
            await MainActor.run {
                self._navigationRoutes = selectedRoutes
                mapView.show(selectedRoutes)
            }
        }
    }

    public func navigationMapViewDidFinishLoadingMap(_ mapView: NavigationMapView) {
        // Wait for the map to load before initiating the first camera movement.
        moveCameraToCenter()
    }

}

extension FlutterMapboxNavigationView : UIGestureRecognizerDelegate {
            
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let location = navigationMapView.mapView.mapboxMap.coordinate(for: gesture.location(in: navigationMapView.mapView))
        requestRoute(destination: location)
    }
    
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {return}
        let location = navigationMapView.mapView.mapboxMap.coordinate(for: gesture.location(in: navigationMapView.mapView))
        let waypoint: Encodable = [
            "latitude" : location.latitude,
            "longitude" : location.longitude,
        ]
        do {
            let encodedData = try JSONEncoder().encode(waypoint)
            let jsonString = String(data: encodedData,
                                    encoding: .utf8)
            
            if (jsonString?.isEmpty ?? true) {
                return
            }
            
            sendEvent(eventType: .on_map_tap,data: jsonString!)
        } catch {
            return
        }
    }

    func requestRoute(destination: CLLocationCoordinate2D) {
        isEmbeddedNavigation = true
        sendEvent(eventType: MapBoxEventType.route_building)

        guard let userLocation = navigationMapView.mapView.location.latestLocation else { return }
        let location = CLLocation(latitude: userLocation.coordinate.latitude,
                                  longitude: userLocation.coordinate.longitude)
        let userWaypoint = Waypoint(location: location, heading: userLocation.heading, name: "Current Location")
        let destinationWaypoint = Waypoint(coordinate: destination)

        let routeOptions = NavigationRouteOptions(waypoints: [userWaypoint, destinationWaypoint])
        self.routeOptions = routeOptions
        
        guard let navigation = mapboxNavigation else { return }
        let routingProvider = navigation.routingProvider()
        
        Task {
            do {
                let routes = try await routingProvider.calculateRoutes(options: routeOptions).value
                
                await MainActor.run {
                    self._navigationRoutes = routes
                    self.sendEvent(eventType: MapBoxEventType.route_built, data: self.encodeNavigationRoutes(routes: routes))
                    self.navigationMapView.show(routes)
                }
            } catch {
                await MainActor.run {
                    print(error.localizedDescription)
                    self.sendEvent(eventType: MapBoxEventType.route_build_failed)
                }
            }
        }
    }

}
