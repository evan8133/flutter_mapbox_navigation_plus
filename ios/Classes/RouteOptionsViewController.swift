import Flutter
import UIKit
import MapboxMaps
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit
import Combine

public class RouteOptionsViewController : UIViewController, NavigationMapViewDelegate
{
    var mapView: NavigationMapView!
    var routeOptions: NavigationRouteOptions?
    var route: Route?
    var navigationRoutes: NavigationRoutes?
    
    private var mapboxNavigationProvider: MapboxNavigationProvider?
    private var mapboxNavigation: MapboxNavigation?
    private var subscriptions = Set<AnyCancellable>()

    init(routes: NavigationRoutes, options: NavigationRouteOptions)
    {
        self.navigationRoutes = routes
        self.routeOptions = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.navigationRoutes = nil
        self.routeOptions = nil
    }


    public override func viewDidLoad() {
        super.viewDidLoad()
        
        setupNavigation()
        setupMapView()
    }
    
    private func setupNavigation() {
        let config = CoreConfig(locationSource: .live)
        mapboxNavigationProvider = MapboxNavigationProvider(coreConfig: config)
        mapboxNavigation = mapboxNavigationProvider?.mapboxNavigation
    }

    private func setupMapView() {
        guard let navigation = mapboxNavigation else { return }
        
        mapView = NavigationMapView(
            location: navigation.navigation().locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.navigation().routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            predictiveCacheManager: navigation.predictiveCacheManager
        )
        mapView.frame = view.bounds
        view.addSubview(mapView)
        mapView.delegate = self

        // Add a gesture recognizer to the map view
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        mapView.addGestureRecognizer(longPress)
    }

    // long press to select a destination
    @objc func didLongPress(_ sender: UILongPressGestureRecognizer){
        guard sender.state == .began else {
            return
        }
        // Long press handling - route calculation is now done via async
    }

    // Calculate route to be used for navigation
    func calculateRoute(from origin: CLLocationCoordinate2D,
                        to destination: CLLocationCoordinate2D,
                        completion: @escaping (NavigationRoutes?, Error?) -> ()) {

        let origin = Waypoint(coordinate: origin, coordinateAccuracy: -1, name: "Start")
        let destination = Waypoint(coordinate: destination, coordinateAccuracy: -1, name: "Finish")

        let routeOptions = NavigationRouteOptions(waypoints: [origin, destination], profileIdentifier: .automobileAvoidingTraffic)

        guard let navigation = mapboxNavigation else {
            completion(nil, NSError(domain: "NavigationError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Navigation not initialized"]))
            return
        }
        
        let routingProvider = navigation.routingProvider()
        
        Task {
            do {
                let routes = try await routingProvider.calculateRoutes(options: routeOptions).value
                await MainActor.run {
                    self.navigationRoutes = routes
                    self.routeOptions = routeOptions
                    self.drawRoute(routes: routes)
                    completion(routes, nil)
                }
            } catch {
                await MainActor.run {
                    completion(nil, error)
                }
            }
        }
    }

    func drawRoute(routes: NavigationRoutes)
    {
        mapView.show(routes)
    }
}
