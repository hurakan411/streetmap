import MapKit
import SwiftUI

struct RemixViewportSnapshot: Equatable {
    struct Segment: Identifiable, Equatable {
        let id: String
        let start: CGPoint
        let end: CGPoint
        let frequency: Int
        let isEstimated: Bool
    }

    let segments: [Segment]
    let viewportAspectRatio: CGFloat
}

struct MapPlaceDetails: Identifiable {
    let id: String
    let name: String
    let address: String?
    let phoneNumber: String?
    let website: URL?
    let coordinate: CLLocationCoordinate2D
    let isLoading: Bool
}

struct MapCanvasView: UIViewRepresentable {
    #if STREETPRINT_DIAGNOSTICS
    @AppStorage("mapDiagnosticStage") private var diagnosticStageRaw = MapDiagnosticStage.normal.rawValue
    #endif
    let segments: [WeightedSegment]
    let segmentsSignature: Int
    let livePoints: [GeoPoint]
    let stats: WalkStats
    let visibleTransportModes: Set<TransportMode>
    let showsPointsOfInterest: Bool
    let mode: MapDisplayMode
    let theme: AppTheme
    let recenterToken: Int
    let targetLocation: CLLocation?
    let reservesBottomControlsSpace: Bool
    let onMapTap: () -> Void
    let onPlaceSelected: (MapPlaceDetails?) -> Void
    let onAnimatedStatsChanged: (WalkStats) -> Void
    let onRemixSnapshotChanged: (RemixViewportSnapshot?) -> Void
    let mapSnapshotRequestToken: Int
    let onMapSnapshotReady: (UIImage?) -> Void

    private var effectiveDisplayMode: MapDisplayMode {
        #if STREETPRINT_DIAGNOSTICS
        let stage = MapDiagnosticStage(rawValue: diagnosticStageRaw) ?? .normal
        return stage == .normal ? mode : stage == .covered ? .excavation : .map
        #else
        return mode
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMapTap: onMapTap,
            onPlaceSelected: onPlaceSelected,
            onAnimatedStatsChanged: onAnimatedStatsChanged,
            onRemixSnapshotChanged: onRemixSnapshotChanged,
            onMapSnapshotReady: onMapSnapshotReady
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MichiMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = true
        mapView.pointOfInterestFilter = showsPointsOfInterest ? .includingAll : .excludingAll
        mapView.selectableMapFeatures = showsPointsOfInterest ? [.pointsOfInterest] : []
        mapView.layoutMargins = attributionLayoutMargins
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTapMap))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = context.coordinator
        mapView.addGestureRecognizer(tapRecognizer)
        #if targetEnvironment(simulator)
        let initialCenter = CLLocationCoordinate2D(latitude: 35.6896, longitude: 139.7006)
        #else
        let initialCenter = CLLocationCoordinate2D(latitude: 35.6814, longitude: 139.7670)
        #endif
        mapView.setRegion(
            MKCoordinateRegion(
                center: initialCenter,
                span: MKCoordinateSpan(latitudeDelta: 0.055, longitudeDelta: 0.055)
            ),
            animated: false
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let timing = MapPerformanceProbe.begin("main.updateUIView")
        defer { MapPerformanceProbe.end(timing) }
        let mode = effectiveDisplayMode
        #if STREETPRINT_DIAGNOSTICS
        let hidesRoutes = diagnosticStageRaw == MapDiagnosticStage.mapOnly.rawValue
        let segments = hidesRoutes ? [] : self.segments
        let segmentsSignature = hidesRoutes ? Int.min : self.segmentsSignature
        let livePoints = hidesRoutes ? [] : self.livePoints
        let visibleTransportModes: Set<TransportMode> = hidesRoutes ? [] : self.visibleTransportModes
        #endif
        context.coordinator.onMapTap = onMapTap
        context.coordinator.onPlaceSelected = onPlaceSelected
        context.coordinator.onAnimatedStatsChanged = onAnimatedStatsChanged
        context.coordinator.onRemixSnapshotChanged = onRemixSnapshotChanged
        context.coordinator.onMapSnapshotReady = onMapSnapshotReady
        context.coordinator.theme = theme
        if theme == .midnightPulse { MidnightHexArtwork.prewarm() }
        if context.coordinator.configuredTheme != theme || context.coordinator.configuredPOI != showsPointsOfInterest {
            configureMap(mapView, showsPointsOfInterest: showsPointsOfInterest)
            context.coordinator.configuredTheme = theme
            context.coordinator.configuredPOI = showsPointsOfInterest
        }
        (mapView as? MichiMapView)?.setRouteOnlyAttributionCover(
            visible: mode == .routesOnly,
            color: UIColor(theme.backgroundColor)
        )
        if mapView.layoutMargins != attributionLayoutMargins {
            UIView.animate(withDuration: 0.25) {
                mapView.layoutMargins = attributionLayoutMargins
                mapView.layoutIfNeeded()
            }
        }

        // GPSが最初に届いた時だけ、固定の初期座標からユーザー位置へ移動します。
        // 以降のGPS更新ではユーザーが手動で動かした地図を尊重します。
        if let coordinate = preferredCurrentLocation(on: mapView)?.coordinate,
           !context.coordinator.hasCenteredOnUser {
            #if targetEnvironment(simulator)
            // 新宿から大久保・高田馬場までのデモ経路全体を初期画面に収める。
            let previewSpan: CLLocationDistance = 5_500
            #else
            let previewSpan: CLLocationDistance = 1_800
            #endif
            mapView.setRegion(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: previewSpan,
                    longitudinalMeters: previewSpan
                ),
                animated: false
            )
            context.coordinator.hasCenteredOnUser = true
        }

        if context.coordinator.centeringSegmentsSignature != segmentsSignature {
            let segmentIDs = Set(segments.map(\.id))
            if !segmentIDs.isEmpty && context.coordinator.segmentIDs.isEmpty && !context.coordinator.hasCenteredOnUser {
                let rect = mapRect(for: segments)
                if !rect.isNull {
                    mapView.setVisibleMapRect(rect,
                        edgePadding: UIEdgeInsets(top: 145, left: 28, bottom: 170, right: 28), animated: false)
                }
            }
            context.coordinator.segmentIDs = segmentIDs
            context.coordinator.centeringSegmentsSignature = segmentsSignature
        }

        let styleSignature = context.coordinator.styleSignature(mode: mode, theme: theme)
        let dataSignature = context.coordinator.dataSignature(
            for: segmentsSignature,
            visibleTransportModes: visibleTransportModes
        )
        context.coordinator.cacheLatestRouteState(
            segments: segments,
            styleSignature: styleSignature,
            dataSignature: dataSignature,
            visibleTransportModes: visibleTransportModes,
            stats: stats,
            livePoints: livePoints,
            theme: theme
        )
        context.coordinator.publishStatsTargetIfNeeded(stats)

        let previousMode = context.coordinator.displayMode
        context.coordinator.displayMode = mode
        if previousMode != mode {
            // 地図あり／経路だけの切替では、経路の座標や順序を変えない。
            // 背景だけを差し替え、実際の経路オーバーレイをそのまま再利用する。
            context.coordinator.switchDisplayMode(to: mode, on: mapView)
        } else if styleSignature != context.coordinator.routeStyleSignature {
            context.coordinator.animateRoutes(
                segments,
                styleSignature: styleSignature,
                dataSignature: dataSignature,
                mode: mode,
                theme: theme,
                visibleTransportModes: visibleTransportModes,
                targetStats: stats,
                on: mapView
            )
        } else {
            let backgroundSignature = context.coordinator.backgroundSignature(mode: mode, theme: theme)
            if backgroundSignature != context.coordinator.routeBackgroundSignature {
                context.coordinator.updateBackground(
                    mode: mode,
                    theme: theme,
                    on: mapView
                )
            }
            if dataSignature != context.coordinator.routeDataSignature || stats != context.coordinator.displayedStats {
                context.coordinator.updateRoutesIncrementally(
                    segments: segments,
                    dataSignature: dataSignature,
                    visibleTransportModes: visibleTransportModes,
                    theme: theme,
                    targetStats: stats,
                    on: mapView
                )
            }
        }
        context.coordinator.updateLiveRoute(
            livePoints,
            visibleTransportModes: visibleTransportModes,
            on: mapView
        )
        context.coordinator.updateExcavationMask(
            mode: mode,
            segments: segments,
            livePoints: livePoints,
            visibleTransportModes: visibleTransportModes,
            on: mapView
        )
        if mode == .routesOnly, context.coordinator.remixOverlay == nil {
            context.coordinator.publishPlainViewportSnapshotIfPossible(on: mapView)
        }

        if recenterToken != context.coordinator.recenterToken {
            context.coordinator.recenterToken = recenterToken
            if let coordinate = preferredCurrentLocation(on: mapView)?.coordinate {
                context.coordinator.centerMap(on: coordinate, mapView: mapView, animated: true)
            } else {
                // 現在地がまだ届いていない場合も、タップを無効にせず次の測位で実行する。
                context.coordinator.shouldRecenterOnNextLocation = true
            }
        } else if context.coordinator.shouldRecenterOnNextLocation,
                  let coordinate = preferredCurrentLocation(on: mapView)?.coordinate {
            context.coordinator.centerMap(on: coordinate, mapView: mapView, animated: true)
        }

        if mapSnapshotRequestToken != context.coordinator.mapSnapshotRequestToken {
            context.coordinator.mapSnapshotRequestToken = mapSnapshotRequestToken
            context.coordinator.captureMapSnapshot(on: mapView)
        }
    }

    private func configureMap(_ mapView: MKMapView, showsPointsOfInterest: Bool) {
        mapView.overrideUserInterfaceStyle = theme.prefersDarkMap ? .dark : .light
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        let pointOfInterestFilter: MKPointOfInterestFilter = showsPointsOfInterest ? .includingAll : .excludingAll
        mapView.pointOfInterestFilter = pointOfInterestFilter
        mapView.selectableMapFeatures = showsPointsOfInterest ? [.pointsOfInterest] : []
        configuration.pointOfInterestFilter = pointOfInterestFilter
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration
        mapView.backgroundColor = UIColor(theme.backgroundColor)
    }

    private func preferredCurrentLocation(on mapView: MKMapView) -> CLLocation? {
        #if targetEnvironment(simulator)
        return targetLocation
        #else
        let freshnessLimit: TimeInterval = 45
        return [targetLocation, mapView.userLocation.location]
            .compactMap { $0 }
            .filter {
                $0.horizontalAccuracy >= 0
                    && CLLocationCoordinate2DIsValid($0.coordinate)
                    && abs($0.timestamp.timeIntervalSinceNow) <= freshnessLimit
            }
            .max { $0.timestamp < $1.timestamp }
        #endif
    }

    private var attributionLayoutMargins: UIEdgeInsets {
        UIEdgeInsets(
            top: 7,
            // Appleマップの法的表示は消せないため、左下の端へ寄せる。
            left: 0,
            // 通常表示では、期間コントロールと重ならない位置に置く。
            // 共有スナップショット時だけUI非表示時の余白へ切り替える。
            // 経路だけビューはApple地図を全面置換するため、下端の専用カバー内へ収める。
            bottom: effectiveDisplayMode == .routesOnly ? 0 : (reservesBottomControlsSpace ? 108 : 4),
            right: 7
        )
    }

    private func mapRect(for segments: [WeightedSegment]) -> MKMapRect {
        segments.reduce(MKMapRect.null) { rect, segment in
            let start = MKMapPoint(segment.start)
            let end = MKMapPoint(segment.end)
            return rect.union(MKMapRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(1, abs(start.x - end.x)),
                height: max(1, abs(start.y - end.y))
            ))
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate {
        var theme: AppTheme = .editorialGlass
        var configuredTheme: AppTheme?
        var configuredPOI: Bool?
        var centeringSegmentsSignature: Int?
        private var routeRenderRevision = 0
        private var plainSnapshotKey: String?
        private let routeState = RouteAnimationState()
        private var routeSurface: PersistentRouteOverlay?
        private weak var routeSurfaceRenderer: PersistentRouteRenderer?
        private var routePreparationTask: Task<Void, Never>?
        private var routePreparationRevision = 0
        var segmentIDs = Set<String>()
        var recenterToken = 0
        var hasCenteredOnUser = false
        var shouldRecenterOnNextLocation = false
        var onMapTap: () -> Void
        var onPlaceSelected: (MapPlaceDetails?) -> Void
        var onAnimatedStatsChanged: (WalkStats) -> Void
        var onRemixSnapshotChanged: (RemixViewportSnapshot?) -> Void
        var onMapSnapshotReady: (UIImage?) -> Void
        var displayedStats = WalkStats.zero
        var routeStyleSignature: Int?
        var routeBackgroundSignature: Int?
        var routeDataSignature: Int?
        var routeAnimationTask: Task<Void, Never>?
        var visibleTransportModes = Set(TransportMode.allCases)
        var liveRouteSignature: Int?
        var displayMode: MapDisplayMode = .map
        fileprivate var remixOverlay: RouteRemixOverlay?
        fileprivate var remixBackground: BackgroundTileOverlay?
        var remixDisplayLink: CADisplayLink?
        weak var remixMapView: MKMapView?
        var remixAnimationStartedAt: CFTimeInterval = 0
        var remixAnimationFrom: CGFloat = 0
        var remixAnimationTo: CGFloat = 1
        var remixAnimationCompletion: (() -> Void)?
        var lastPublishedRemixSnapshot: RemixViewportSnapshot?
        var latestSegments: [WeightedSegment] = []
        var latestLivePoints: [GeoPoint] = []
        var latestVisibleTransportModes = Set(TransportMode.allCases)
        var latestStats = WalkStats.zero
        var latestStyleSignature = 0
        var latestDataSignature = 0
        var latestTheme: AppTheme = .editorialGlass
        var mapSnapshotRequestToken = 0
        private var excavationMask: ExcavationMaskTileOverlay?
        private var excavationMaskSignature: Int?
        private var maskPreparationTask: Task<Void, Never>?
        private var shouldSuppressMapTap = false
        private var selectedPlaceRequestToken = UUID()
        private var selectedPlaceRequest: MKMapItemRequest?
        private weak var placeDetailController: UIViewController?
        private weak var placeDetailMapView: MKMapView?
        private var pendingMapTap: DispatchWorkItem?

        init(
            onMapTap: @escaping () -> Void,
            onPlaceSelected: @escaping (MapPlaceDetails?) -> Void,
            onAnimatedStatsChanged: @escaping (WalkStats) -> Void,
            onRemixSnapshotChanged: @escaping (RemixViewportSnapshot?) -> Void,
            onMapSnapshotReady: @escaping (UIImage?) -> Void
        ) {
            self.onMapTap = onMapTap
            self.onPlaceSelected = onPlaceSelected
            self.onAnimatedStatsChanged = onAnimatedStatsChanged
            self.onRemixSnapshotChanged = onRemixSnapshotChanged
            self.onMapSnapshotReady = onMapSnapshotReady
        }

        @objc func didTapMap() {
            pendingMapTap?.cancel()
            let action = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !shouldSuppressMapTap, placeDetailController == nil else { return }
                onMapTap()
            }
            pendingMapTap = action
            // MapKit resolves a POI tap after its double-tap recognizer has
            // finished. Cancel this background action if didSelect arrives.
            let delay = configuredPOI == true && displayMode != .routesOnly ? 0.45 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            guard let feature = annotation as? MKMapFeatureAnnotation,
                  feature.featureType == .pointOfInterest else { return }
            pendingMapTap?.cancel()
            pendingMapTap = nil

            if !isSelectablePlace(feature, on: mapView) {
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }

            suppressMapTapForPlaceSelection()
            if #available(iOS 18.0, *) {
                onPlaceSelected(nil)
                presentPlaceDetails(for: feature, on: mapView)
                return
            }
            let requestToken = UUID()
            selectedPlaceRequestToken = requestToken
            let coordinate = feature.coordinate
            let title = feature.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = (title?.isEmpty == false ? title : nil) ?? NSLocalizedString("場所", comment: "Selected map place")
            let featureID = "\(fallbackName)|\(coordinate.latitude)|\(coordinate.longitude)"
            onPlaceSelected(MapPlaceDetails(
                id: featureID,
                name: fallbackName,
                address: feature.subtitle,
                phoneNumber: nil,
                website: nil,
                coordinate: coordinate,
                isLoading: true
            ))

            let request = MKMapItemRequest(mapFeatureAnnotation: feature)
            request.getMapItem { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.selectedPlaceRequestToken == requestToken else { return }
                    guard let item else {
                        self.onPlaceSelected(MapPlaceDetails(
                            id: featureID,
                            name: fallbackName,
                            address: feature.subtitle,
                            phoneNumber: nil,
                            website: nil,
                            coordinate: coordinate,
                            isLoading: false
                        ))
                        return
                    }
                    let mapItemName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = (mapItemName?.isEmpty == false ? mapItemName : nil) ?? fallbackName
                    let placemarkTitle = item.placemark.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let address = (placemarkTitle?.isEmpty == false && placemarkTitle != name)
                        ? placemarkTitle
                        : feature.subtitle
                    self.onPlaceSelected(MapPlaceDetails(
                        id: featureID,
                        name: name,
                        address: address,
                        phoneNumber: item.phoneNumber,
                        website: item.url,
                        coordinate: item.placemark.coordinate,
                        isLoading: false
                    ))
                }
            }
        }

        private func suppressMapTapForPlaceSelection() {
            shouldSuppressMapTap = true
            // POI選択と同じタップが地図用ジェスチャーにも届く場合だけ抑止する。
            // MapKitが地図タップを発火しないケースでも、次回の背景タップを誤って無視しない。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.shouldSuppressMapTap = false
            }
        }

        @available(iOS 18.0, *)
        func mapView(_ mapView: MKMapView, selectionAccessoryFor annotation: any MKAnnotation) -> MKSelectionAccessory? {
            // Present the detail controller ourselves so MapKit cannot select
            // a full-screen sheet or present a second accessory over our card.
            nil
        }

        @available(iOS 18.0, *)
        private func presentPlaceDetails(for feature: MKMapFeatureAnnotation, on mapView: MKMapView) {
            var responder: UIResponder? = mapView
            var presenter: UIViewController?
            while let current = responder {
                if let controller = current as? UIViewController {
                    presenter = controller
                    break
                }
                responder = current.next
            }
            guard let presenter, presenter.presentedViewController == nil else { return }

            selectedPlaceRequest?.cancel()
            let requestToken = UUID()
            selectedPlaceRequestToken = requestToken
            // Resolve the exact tapped POI before presenting the rich card,
            // so the controller starts with the complete map item, not nil.
            let request = MKMapItemRequest(mapFeatureAnnotation: feature)
            selectedPlaceRequest = request
            request.getMapItem { [weak self, weak mapView, weak presenter] item, _ in
                DispatchQueue.main.async {
                    guard let self, let mapView, let presenter,
                          self.selectedPlaceRequestToken == requestToken else { return }
                    self.selectedPlaceRequest = nil
                    if let item, presenter.presentedViewController == nil {
                        self.showPlaceDetails(item, from: presenter, on: mapView)
                    } else if item == nil {
                        self.onPlaceSelected(MapPlaceDetails(
                            id: "\(feature.coordinate.latitude)|\(feature.coordinate.longitude)",
                            name: feature.title ?? NSLocalizedString("場所", comment: "Selected map place"),
                            address: feature.subtitle,
                            phoneNumber: nil,
                            website: nil,
                            coordinate: feature.coordinate,
                            isLoading: false
                        ))
                    }
                }
            }
        }

        @available(iOS 18.0, *)
        private func showPlaceDetails(_ item: MKMapItem, from presenter: UIViewController, on mapView: MKMapView) {
            let detail = MKMapItemDetailViewController(mapItem: item, displaysMap: false)
            detail.delegate = self
            detail.modalPresentationStyle = .pageSheet
            if let sheet = detail.sheetPresentationController {
                // A single detent keeps the map visible even while scrolling
                // the place information. Never expand to a full-screen card.
                let compact = UISheetPresentationController.Detent.Identifier("streetprint.place.compact")
                sheet.detents = [.custom(identifier: compact) { context in
                    min(380, context.maximumDetentValue * 0.44)
                }]
                sheet.selectedDetentIdentifier = compact
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                sheet.prefersEdgeAttachedInCompactHeight = true
                sheet.preferredCornerRadius = 24
            }
            placeDetailController = detail
            placeDetailMapView = mapView
            presenter.present(detail, animated: true)
            detail.presentationController?.delegate = self
        }

        fileprivate func finishPlaceDetails(_ controller: UIViewController, dismiss: Bool, completion: (() -> Void)? = nil) {
            guard placeDetailController === controller else { return }
            selectedPlaceRequestToken = UUID()
            selectedPlaceRequest?.cancel()
            selectedPlaceRequest = nil
            placeDetailController = nil
            let mapView = placeDetailMapView
            placeDetailMapView = nil
            let finish = {
                mapView?.selectedAnnotations.compactMap { $0 as? MKMapFeatureAnnotation }.forEach {
                    mapView?.deselectAnnotation($0, animated: false)
                }
                completion?()
            }
            if dismiss {
                controller.dismiss(animated: true, completion: finish)
            } else {
                finish()
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishPlaceDetails(presentationController.presentedViewController, dismiss: false)
        }

        private func isSelectablePlace(_ feature: MKMapFeatureAnnotation, on mapView: MKMapView) -> Bool {
            guard configuredPOI == true, displayMode != .routesOnly else { return false }
            guard displayMode == .excavation else { return true }
            return (mapView as? MichiMapView)?.midnightHexMask?.contains(feature.coordinate)
                ?? excavationMask?.contains(feature.coordinate) ?? false
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: any MKAnnotation) {
            guard annotation is MKMapFeatureAnnotation else { return }
            guard placeDetailController == nil else { return }
            selectedPlaceRequestToken = UUID()
            selectedPlaceRequest?.cancel()
            selectedPlaceRequest = nil
            onPlaceSelected(nil)
        }

        func captureMapSnapshot(on mapView: MKMapView) {
            guard displayMode != .routesOnly, mapView.bounds.width > 1, mapView.bounds.height > 1 else {
                DispatchQueue.main.async { [onMapSnapshotReady] in
                    onMapSnapshotReady(nil)
                }
                return
            }
            (mapView as? MichiMapView)?.midnightHexMask?.finishEntryAnimation()
            let originalMargins = mapView.layoutMargins
            // 共有画像では、UIを消した状態と同じ最下部へ帰属表示を置く。
            mapView.layoutMargins = UIEdgeInsets(top: 7, left: 0, bottom: 4, right: 7)
            mapView.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(size: mapView.bounds.size)
            let image = renderer.image { context in
                mapView.drawHierarchy(in: mapView.bounds, afterScreenUpdates: true)
            }
            mapView.layoutMargins = originalMargins
            mapView.layoutIfNeeded()
            // SwiftUIのUIViewRepresentable更新中にsheetを直接開かない。
            // 次のRunLoopへ渡してから共有画像を生成する。
            DispatchQueue.main.async { [onMapSnapshotReady] in
                onMapSnapshotReady(image)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // A pinch/pan/rotation belongs to MapKit, not the UI visibility
            // toggle. In particular, lifting the last finger after zooming
            // must not also change the map's layout margins.
            otherGestureRecognizer is UITapGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Let MapKit finish double-tap zoom before deciding that this was
            // a single background tap. POI single-tap selection still works.
            guard let tap = otherGestureRecognizer as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired > 1
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            #if targetEnvironment(simulator)
            // 掲載画像用シミュレーターではMac側の位置情報を現在地にしない。
            return
            #endif
            guard let location = userLocation.location,
                  location.horizontalAccuracy >= 0,
                  abs(location.timestamp.timeIntervalSinceNow) <= 45,
                  CLLocationCoordinate2DIsValid(location.coordinate) else { return }

            if !hasCenteredOnUser || shouldRecenterOnNextLocation {
                centerMap(
                    on: location.coordinate,
                    mapView: mapView,
                    animated: hasCenteredOnUser
                )
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            MapPerformanceProbe.regionWillChange()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MapPerformanceProbe.regionDidChange()
            let timing = MapPerformanceProbe.begin("main.regionDidChange")
            defer { MapPerformanceProbe.end(timing) }
            updateExcavationScale(on: mapView, settled: true)
            if remixOverlay == nil {
                publishPlainViewportSnapshotIfPossible(on: mapView)
            } else {
                publishRemixSnapshotIfPossible(on: mapView)
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let timing = MapPerformanceProbe.begin("main.visibleRegionChanged")
            defer { MapPerformanceProbe.end(timing) }
            updateExcavationScale(on: mapView)
        }

        private func updateExcavationScale(on mapView: MKMapView, settled: Bool = false) {
            let timing = MapPerformanceProbe.begin("main.maskViewport")
            defer { MapPerformanceProbe.end(timing) }
            guard mapView.visibleMapRect.width > 0 else { return }
            (mapView as? MichiMapView)?.midnightHexMask?.refreshViewport()
            excavationMask?.updateViewport(mapView.visibleMapRect,
                zoomScale: Double(mapView.bounds.width) / mapView.visibleMapRect.width, settled: settled)
        }

        // MapKitの標準ユーザー位置ビューは、精度サークル（白い輪）を
        // 表示することがあるため、アプリの小さな現在地ドットに置き換える。
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKUserLocation else { return nil }
            let reuseIdentifier = "MichiUserLocation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                as? MichiUserLocationView)
                ?? MichiUserLocationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            return view
        }

        func centerMap(on coordinate: CLLocationCoordinate2D, mapView: MKMapView, animated: Bool) {
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            #if targetEnvironment(simulator)
            let previewSpan: CLLocationDistance = 5_500
            #else
            let previewSpan: CLLocationDistance = 1_800
            #endif
            mapView.setRegion(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: previewSpan,
                    longitudinalMeters: previewSpan
                ),
                animated: animated
            )
            hasCenteredOnUser = true
            shouldRecenterOnNextLocation = false
        }

        func cacheLatestRouteState(
            segments: [WeightedSegment],
            styleSignature: Int,
            dataSignature: Int,
            visibleTransportModes: Set<TransportMode>,
            stats: WalkStats,
            livePoints: [GeoPoint],
            theme: AppTheme
        ) {
            latestSegments = segments
            latestStyleSignature = styleSignature
            latestDataSignature = dataSignature
            latestVisibleTransportModes = visibleTransportModes
            latestStats = stats
            latestLivePoints = livePoints
            latestTheme = theme
        }

        func beginRemix(
            segments: [WeightedSegment],
            visibleTransportModes: Set<TransportMode>,
            theme: AppTheme,
            on mapView: MKMapView
        ) {
            routeAnimationTask?.cancel()
            routePreparationTask?.cancel()
            routePreparationRevision &+= 1
            stopRemixAnimation()
            mapView.showsUserLocation = false

            let renderedIDs = renderedCoreSegmentIDs(on: mapView)
            var sources = segments.compactMap { segment -> RemixSourceSegment? in
                guard visibleTransportModes.contains(segment.transportMode),
                      (renderedIDs.isEmpty || renderedIDs.contains(segment.id)),
                      isVisibleOnScreen(start: segment.start, end: segment.end, mapView: mapView) else {
                    return nil
                }
                return RemixSourceSegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    frequency: segment.frequency,
                    isEstimated: segment.isEstimated,
                    visitedAt: segment.firstVisitedAt,
                    transportMode: segment.transportMode
                )
            }

            for pair in zip(latestLivePoints, latestLivePoints.dropFirst()) {
                guard pair.1.connects(from: pair.0) else { continue }
                let mode = pair.1.resolvedTransportMode
                guard visibleTransportModes.contains(mode),
                      isVisibleOnScreen(start: pair.0.coordinate, end: pair.1.coordinate, mapView: mapView) else {
                    continue
                }
                sources.append(RemixSourceSegment(
                    id: "live:\(pair.0.id):\(pair.1.id)",
                    start: pair.0.coordinate,
                    end: pair.1.coordinate,
                    frequency: 1,
                    isEstimated: pair.0.estimated || pair.1.estimated,
                    visitedAt: min(pair.0.timestamp, pair.1.timestamp),
                    transportMode: mode
                ))
            }

            let oldOverlays = mapView.overlays.filter {
                $0 is PersistentRouteOverlay || $0 is LivePolyline || $0 is RouteRemixOverlay
                    || $0 is BackgroundTileOverlay || $0 is MapTintOverlay
                    || $0 is ExcavationMaskTileOverlay
            }
            if !oldOverlays.isEmpty { mapView.removeOverlays(oldOverlays) }
            resetRoutePresentation()
            (mapView as? MichiMapView)?.setMidnightHexSurface(nil)
            excavationMask?.invalidate()
            excavationMask = nil
            excavationMaskSignature = nil

            let viewport = mapView.visibleMapRect
            let remixedSegments = makeRemixedSegments(from: sources, inside: viewport)
            let overlay = RouteRemixOverlay(
                segments: remixedSegments,
                viewport: viewport,
                theme: theme
            )
            let background = BackgroundTileOverlay(color: UIColor(theme.backgroundColor))
            remixOverlay = overlay
            remixBackground = background
            remixMapView = mapView
            lastPublishedRemixSnapshot = nil
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(nil)
            }

            mapView.addOverlay(background, level: .aboveLabels)
            mapView.addOverlay(overlay, level: .aboveLabels)
            mapView.renderer(for: background)?.alpha = 0
            routeBackgroundSignature = backgroundSignature(mode: .routesOnly, theme: theme)

            startRemixAnimation(from: 0, to: 1, on: mapView) { [weak self, weak mapView] in
                guard let self, let mapView, self.displayMode == .routesOnly else { return }
                self.publishRemixSnapshotIfPossible(on: mapView)
            }
        }

        func endRemix(on mapView: MKMapView) {
            guard let overlay = remixOverlay else {
                restoreNormalRoutes(mode: .map, on: mapView)
                return
            }
            lastPublishedRemixSnapshot = nil
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(nil)
            }
            startRemixAnimation(from: overlay.progress, to: 0, on: mapView) { [weak self, weak mapView] in
                guard let self, let mapView, self.displayMode != .routesOnly else { return }
                self.restoreNormalRoutes(mode: self.displayMode, on: mapView)
            }
        }

        /// モード切替時は経路の描画面を触らず、背景だけを交換する。
        /// これにより、地図あり→経路だけで線が描き直されることがない。
        func switchDisplayMode(to mode: MapDisplayMode, on mapView: MKMapView) {
            stopRemixAnimation()
            let backgroundOverlays = mapView.overlays.filter {
                $0 is RouteRemixOverlay || $0 is BackgroundTileOverlay || $0 is MapTintOverlay
                    || $0 is ExcavationMaskTileOverlay
            }
            if !backgroundOverlays.isEmpty {
                mapView.removeOverlays(backgroundOverlays)
            }
            remixOverlay = nil
            remixBackground = nil
            remixMapView = nil
            (mapView as? MichiMapView)?.setMidnightHexSurface(nil)
            excavationMask?.invalidate()
            excavationMask = nil
            excavationMaskSignature = nil
            lastPublishedRemixSnapshot = nil
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(nil)
            }
            mapView.showsUserLocation = mode != .routesOnly
            updateBackground(mode: mode, theme: latestTheme, on: mapView)
        }

        func updateRemix(
            theme: AppTheme,
            activeSegmentIDs: Set<String>,
            visibleTransportModes: Set<TransportMode>,
            on mapView: MKMapView
        ) {
            guard let overlay = remixOverlay else { return }
            overlay.apply(theme: theme)
            overlay.activeSegmentIDs = activeSegmentIDs.union(
                overlay.segments.lazy.filter { $0.id.hasPrefix("live:") }.map(\.id)
            )
            overlay.visibleTransportModes = visibleTransportModes
            mapView.renderer(for: overlay)?.setNeedsDisplay()

            guard overlay.themeIdentifier != theme.rawValue else { return }
            overlay.themeIdentifier = theme.rawValue
            if let oldBackground = remixBackground {
                mapView.removeOverlay(oldBackground)
            }
            let background = BackgroundTileOverlay(color: UIColor(theme.backgroundColor))
            remixBackground = background
            mapView.insertOverlay(background, below: overlay)
            mapView.renderer(for: background)?.alpha = overlay.progress
        }

        func publishStatsTargetIfNeeded(_ stats: WalkStats) {
            publishStatsTarget(stats)
        }

        private func startRemixAnimation(
            from: CGFloat,
            to: CGFloat,
            on mapView: MKMapView,
            completion: @escaping () -> Void
        ) {
            stopRemixAnimation()
            remixMapView = mapView
            remixAnimationFrom = from
            remixAnimationTo = to
            remixAnimationStartedAt = CACurrentMediaTime()
            remixAnimationCompletion = completion
            remixOverlay?.progress = from
            let displayLink = CADisplayLink(target: self, selector: #selector(stepRemixAnimation(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            displayLink.add(to: .main, forMode: .common)
            remixDisplayLink = displayLink
        }

        @objc private func stepRemixAnimation(_ displayLink: CADisplayLink) {
            guard let overlay = remixOverlay, let mapView = remixMapView else {
                stopRemixAnimation()
                return
            }
            let elapsed = CACurrentMediaTime() - remixAnimationStartedAt
            let linear = min(1, max(0, elapsed / 2.0))
            let eased = linear * linear * (3 - 2 * linear)
            let progress = remixAnimationFrom + (remixAnimationTo - remixAnimationFrom) * CGFloat(eased)
            overlay.progress = progress
            mapView.renderer(for: overlay)?.setNeedsDisplay()
            if let background = remixBackground {
                mapView.renderer(for: background)?.alpha = progress
            }

            guard linear >= 1 else { return }
            let completion = remixAnimationCompletion
            stopRemixAnimation()
            completion?()
        }

        private func stopRemixAnimation() {
            remixDisplayLink?.invalidate()
            remixDisplayLink = nil
            remixAnimationCompletion = nil
        }

        func restoreNormalRoutes(mode: MapDisplayMode, on mapView: MKMapView) {
            stopRemixAnimation()
            routeAnimationTask?.cancel()
            routeAnimationTask = nil
            lastPublishedRemixSnapshot = nil
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(nil)
            }
            let disposable = mapView.overlays.filter {
                $0 is RouteRemixOverlay || $0 is PersistentRouteOverlay || $0 is LivePolyline
                    || $0 is BackgroundTileOverlay || $0 is MapTintOverlay
                    || $0 is ExcavationMaskTileOverlay
            }
            if !disposable.isEmpty { mapView.removeOverlays(disposable) }
            resetRoutePresentation()
            remixOverlay = nil
            remixBackground = nil
            remixMapView = nil
            (mapView as? MichiMapView)?.setMidnightHexSurface(nil)
            excavationMask?.invalidate()
            excavationMask = nil
            excavationMaskSignature = nil
            mapView.showsUserLocation = mode != .routesOnly

            theme = latestTheme
            updateBackground(mode: mode, theme: latestTheme, on: mapView)
            clearRouteBatch(on: mapView)
            routeStyleSignature = latestStyleSignature
            routeDataSignature = latestDataSignature
            prepareRouteTransition(latestSegments, modes: latestVisibleTransportModes,
                dataSignature: latestDataSignature, theme: latestTheme, animated: false, on: mapView)
            visibleTransportModes = latestVisibleTransportModes
            publishStatsTarget(latestStats)
            liveRouteSignature = nil
            updateLiveRoute(
                latestLivePoints,
                visibleTransportModes: latestVisibleTransportModes,
                on: mapView
            )
        }

        func publishRemixSnapshotIfPossible(on mapView: MKMapView) {
            guard displayMode == .routesOnly,
                  let overlay = remixOverlay,
                  overlay.progress >= 0.999,
                  mapView.bounds.width > 1,
                  mapView.bounds.height > 1 else { return }

            let bounds = mapView.bounds
            let visible = overlay.segments.compactMap { segment -> RemixViewportSnapshot.Segment? in
                guard overlay.activeSegmentIDs.contains(segment.id),
                      overlay.visibleTransportModes.contains(segment.transportMode) else { return nil }
                let startCoordinate = segment.targetStart.coordinate
                let endCoordinate = segment.targetEnd.coordinate
                let start = mapView.convert(startCoordinate, toPointTo: mapView)
                let end = mapView.convert(endCoordinate, toPointTo: mapView)
                let lineBounds = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: max(1, abs(start.x - end.x)),
                    height: max(1, abs(start.y - end.y))
                ).insetBy(dx: -4, dy: -4)
                guard lineBounds.intersects(bounds) else { return nil }
                return RemixViewportSnapshot.Segment(
                    id: segment.id,
                    start: CGPoint(x: start.x / bounds.width, y: start.y / bounds.height),
                    end: CGPoint(x: end.x / bounds.width, y: end.y / bounds.height),
                    frequency: segment.frequency,
                    isEstimated: segment.isEstimated
                )
            }.sorted { $0.id < $1.id }
            let snapshot = RemixViewportSnapshot(
                segments: visible,
                viewportAspectRatio: bounds.width / bounds.height
            )
            guard snapshot != lastPublishedRemixSnapshot else { return }
            lastPublishedRemixSnapshot = snapshot
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(snapshot)
            }
        }

        private func isVisibleOnScreen(
            start: CLLocationCoordinate2D,
            end: CLLocationCoordinate2D,
            mapView: MKMapView
        ) -> Bool {
            let first = mapView.convert(start, toPointTo: mapView)
            let second = mapView.convert(end, toPointTo: mapView)
            let bounds = CGRect(
                x: min(first.x, second.x),
                y: min(first.y, second.y),
                width: max(1, abs(first.x - second.x)),
                height: max(1, abs(first.y - second.y))
            ).insetBy(dx: -4, dy: -4)
            return bounds.intersects(mapView.bounds)
        }

        private func makeRemixedSegments(
            from sources: [RemixSourceSegment],
            inside viewport: MKMapRect
        ) -> [RouteRemixOverlay.Segment] {
            guard !sources.isEmpty, viewport.width > 0, viewport.height > 0 else { return [] }
            var result: [RouteRemixOverlay.Segment] = []
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: sources) {
                calendar.startOfDay(for: $0.visitedAt)
            }
            let days = grouped.keys.sorted()
            let laneCount = max(1, days.count)

            // 地図上の関係は壊すが、日ごとの時系列は残す。
            // その日の線は同じレーン上を順番につなぎ、日付が変わると次のレーンへ移る。
            for (dayIndex, day) in days.enumerated() {
                guard let daySources = grouped[day]?.sorted(by: {
                    if $0.visitedAt == $1.visitedAt { return $0.id < $1.id }
                    return $0.visitedAt < $1.visitedAt
                }) else { continue }

                var generator = SplitMix64(seed: UInt64(dayIndex + 1) &* 0x9E3779B97F4A7C15)
                let rowY = 0.08 + 0.84 * (CGFloat(dayIndex) + 0.5) / CGFloat(laneCount)
                var cursor = CGPoint(x: 0.07, y: rowY)
                var direction: CGFloat = dayIndex.isMultiple(of: 2) ? 0 : .pi

                for source in daySources {
                let sourceStart = MKMapPoint(source.start)
                let sourceEnd = MKMapPoint(source.end)
                let sourceLength = hypot(
                    sourceEnd.x - sourceStart.x,
                    sourceEnd.y - sourceStart.y
                )
                let normalizedLength = sourceLength / viewport.width
                let turn = (generator.unitCGFloat() - 0.5) * 0.22
                let angle = direction + turn
                var start = cursor
                var end = CGPoint(
                    x: start.x + CGFloat(cos(angle)) * CGFloat(normalizedLength),
                    y: start.y + CGFloat(sin(angle)) * CGFloat(sourceLength / viewport.height)
                )

                // 端に到達したら、線を縮めず次の折り返しレーンへ移る。
                if end.x < 0.04 || end.x > 0.96 {
                    start = CGPoint(
                        x: direction > .pi / 2 ? 0.93 : 0.07,
                        y: min(0.96, max(0.04, cursor.y + 0.028))
                    )
                    direction = direction > .pi / 2 ? 0 : .pi
                    end = CGPoint(
                        x: start.x + CGFloat(cos(direction)) * CGFloat(normalizedLength),
                        y: start.y + CGFloat(sin(direction)) * CGFloat(sourceLength / viewport.height)
                    )
                }

                result.append(RouteRemixOverlay.Segment(
                    id: source.id,
                    sourceStart: sourceStart,
                    sourceEnd: sourceEnd,
                    targetStart: MKMapPoint(
                        x: viewport.minX + Double(start.x) * viewport.width,
                        y: viewport.minY + Double(start.y) * viewport.height
                    ),
                    targetEnd: MKMapPoint(
                        x: viewport.minX + Double(end.x) * viewport.width,
                        y: viewport.minY + Double(end.y) * viewport.height
                    ),
                    frequency: source.frequency,
                    isEstimated: source.isEstimated,
                    transportMode: source.transportMode
                ))
                    cursor = end
                    direction += (generator.unitCGFloat() - 0.5) * 0.08
                }
            }
            return result
        }

        func styleSignature(mode: MapDisplayMode, theme: AppTheme) -> Int {
            var hasher = Hasher()
            hasher.combine(theme.rawValue)
            return hasher.finalize()
        }

        func backgroundSignature(mode: MapDisplayMode, theme: AppTheme) -> Int {
            var hasher = Hasher()
            hasher.combine(mode.rawValue)
            hasher.combine(theme.rawValue)
            return hasher.finalize()
        }

        func dataSignature(for segmentsSignature: Int, visibleTransportModes: Set<TransportMode>) -> Int {
            var hasher = Hasher()
            hasher.combine(segmentsSignature)
            for mode in TransportMode.allCases where visibleTransportModes.contains(mode) { hasher.combine(mode.rawValue) }
            return hasher.finalize()
        }

        func animateRoutes(
            _ segments: [WeightedSegment], styleSignature: Int, dataSignature: Int,
            mode: MapDisplayMode, theme: AppTheme, visibleTransportModes: Set<TransportMode>,
            targetStats: WalkStats, on mapView: MKMapView
        ) {
            routeAnimationTask?.cancel()
            routeStyleSignature = styleSignature
            routeDataSignature = dataSignature
            self.visibleTransportModes = visibleTransportModes
            publishStatsTarget(targetStats)
            clearRouteBatch(on: mapView)
            updateBackground(mode: mode, theme: theme, on: mapView)
            prepareRouteTransition(segments, modes: visibleTransportModes, dataSignature: dataSignature,
                theme: theme, on: mapView)
        }

        // 地図あり／経路だけの切替では、背景だけを交換して経路オーバーレイを維持する。
        func updateBackground(mode: MapDisplayMode, theme: AppTheme, on mapView: MKMapView) {
            let oldBackgroundOverlays = mapView.overlays.filter {
                $0 is BackgroundTileOverlay || $0 is MapTintOverlay
            }
            if !oldBackgroundOverlays.isEmpty {
                mapView.removeOverlays(oldBackgroundOverlays)
            }

            if mode == .routesOnly {
                let tile = BackgroundTileOverlay(color: UIColor(theme.backgroundColor))
                // 既存の経路線を再追加せず、背景タイルだけを線の下へ差し込む。
                if let routeOverlay = mapView.overlays.first(where: {
                    $0 is PersistentRouteOverlay || $0 is LivePolyline
                }) {
                    mapView.insertOverlay(tile, below: routeOverlay)
                } else {
                    mapView.addOverlay(tile, level: .aboveLabels)
                }
            }
            routeBackgroundSignature = backgroundSignature(mode: mode, theme: theme)
        }

        func updateExcavationMask(
            mode: MapDisplayMode,
            segments: [WeightedSegment],
            livePoints: [GeoPoint],
            visibleTransportModes: Set<TransportMode>,
            on mapView: MKMapView
        ) {
            guard mode == .excavation else {
                maskPreparationTask?.cancel()
                (mapView as? MichiMapView)?.setMidnightHexSurface(nil)
                if let excavationMask {
                    excavationMask.invalidate()
                    mapView.removeOverlay(excavationMask)
                    self.excavationMask = nil
                }
                excavationMaskSignature = nil
                return
            }

            var hasher = Hasher()
            hasher.combine(latestDataSignature)
            hasher.combine(theme.rawValue)
            for (start, end) in zip(livePoints, livePoints.dropFirst())
                where end.connects(from: start) && visibleTransportModes.contains(end.resolvedTransportMode) {
                hasher.combine(start.id)
                hasher.combine(end.id)
            }
            let signature = hasher.finalize()
            guard signature != excavationMaskSignature else { return }
            excavationMaskSignature = signature
            maskPreparationTask?.cancel()
            let requestedTheme = theme
            maskPreparationTask = Task { @MainActor [weak self, weak mapView] in
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                let worker = Task.detached(priority: .userInitiated) { () -> ([TornPaperRenderer.Segment], PaperSegmentIndex)? in
                    var lines = segments.filter { visibleTransportModes.contains($0.transportMode) }.map {
                        TornPaperRenderer.Segment(start: MKMapPoint($0.start), end: MKMapPoint($0.end))
                    }
                    for (start, end) in zip(livePoints, livePoints.dropFirst())
                        where end.connects(from: start) && visibleTransportModes.contains(end.resolvedTransportMode) {
                        lines.append(.init(start: MKMapPoint(start.coordinate), end: MKMapPoint(end.coordinate)))
                    }
                    guard !Task.isCancelled else { return nil }
                    let index = PaperSegmentIndex(segments: lines)
                    return Task.isCancelled ? nil : (lines, index)
                }
                let prepared = await withTaskCancellationHandler(operation: { await worker.value },
                    onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, let mapView, let prepared,
                      self.excavationMaskSignature == signature, self.displayMode == .excavation,
                      self.theme == requestedTheme else { return }
                self.applyExcavationMask(segments: prepared.0, index: prepared.1, on: mapView)
            }
        }

        private func applyExcavationMask(segments maskSegments: [TornPaperRenderer.Segment],
                                         index: PaperSegmentIndex, on mapView: MKMapView) {
            // Only entering this mode animates the captured screen. Subsequent
            // route/filter updates reuse the same geographic cells immediately.
            if theme == .midnightPulse, let excavationMask, let hex = excavationMask.hexSurface {
                hex.update(segments: maskSegments, preparedIndex: index)
                excavationMask.updateViewport(mapView.visibleMapRect,
                    zoomScale: Double(mapView.bounds.width) / max(1, mapView.visibleMapRect.width))
                return
            }
            if let excavationMask {
                excavationMask.invalidate()
                mapView.removeOverlay(excavationMask)
            }
            (mapView as? MichiMapView)?.setMidnightHexSurface(nil)
            let overlay = ExcavationMaskTileOverlay(
                segments: maskSegments, darkPaper: theme.prefersDarkMap, preparedIndex: index
            )
            overlay.updateViewport(mapView.visibleMapRect,
                zoomScale: Double(mapView.bounds.width) / max(1, mapView.visibleMapRect.width))
            excavationMask = overlay
            if let hex = overlay.hexSurface {
                (mapView as? MichiMapView)?.setMidnightHexSurface(hex)
                return
            }
            let overlays = mapView.overlays
            let routeIndex = overlays.firstIndex(where: { candidate in
                candidate is PersistentRouteOverlay || candidate is LivePolyline
            }) ?? overlays.count
            mapView.insertOverlay(overlay, at: routeIndex, level: .aboveLabels)
        }

        func updateRoutesIncrementally(
            segments: [WeightedSegment], dataSignature: Int,
            visibleTransportModes: Set<TransportMode>, theme: AppTheme,
            targetStats: WalkStats, on mapView: MKMapView
        ) {
            publishStatsTarget(targetStats)
            guard routeDataSignature != dataSignature else { return }
            routeDataSignature = dataSignature
            self.visibleTransportModes = visibleTransportModes
            prepareRouteTransition(segments, modes: visibleTransportModes, dataSignature: dataSignature,
                theme: theme, on: mapView)
        }

        private func prepareRouteTransition(_ segments: [WeightedSegment], modes: Set<TransportMode>,
                                            dataSignature: Int, theme: AppTheme, animated: Bool = true, on mapView: MKMapView) {
            routePreparationTask?.cancel()
            routeAnimationTask?.cancel()
            routePreparationRevision &+= 1
            let revision = routePreparationRevision
            let previous = routeState.snapshot()
            let style = routeStyleSignature
            let color = theme.uiRouteColor.cgColor, lineScale = theme.lineScale
            routePreparationTask = Task { @MainActor [weak self, weak mapView] in
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                let worker = Task.detached(priority: .userInitiated) { () -> (RouteRenderPlan, RouteDrawingPalette)? in
                    let old = previous.map { $0.plan.visibleSegments(at: $0.step) } ?? []
                    guard let plan = RouteRenderPlan(previous: old, target: segments.filter { modes.contains($0.transportMode) }) else { return nil }
                    let palette = RouteDrawingPalette(styles: plan.styles, color: color, lineScale: lineScale)
                    return Task.isCancelled ? nil : (plan, palette)
                }
                let prepared = await withTaskCancellationHandler(operation: { await worker.value },
                    onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, let mapView, let prepared,
                      self.routePreparationRevision == revision, self.routeStyleSignature == style,
                      self.routeDataSignature == dataSignature else { return }
                let plan = prepared.0
                self.routeState.install(plan, palette: prepared.1)
                self.ensureRouteSurface(for: plan.bounds, on: mapView)
                if animated {
                    self.animateRouteChanges(plan, revision: revision, dataSignature: dataSignature,
                        styleSignature: style, theme: theme, on: mapView)
                } else {
                    self.applyRouteSteps(plan, from: 0, to: plan.stepCount, theme: theme, on: mapView)
                    self.routeRenderRevision &+= 1
                    self.publishPlainViewportSnapshotIfPossible(on: mapView)
                }
            }
        }

        private func animateRouteChanges(_ plan: RouteRenderPlan, revision: Int, dataSignature: Int,
                                         styleSignature: Int?, theme: AppTheme, on mapView: MKMapView) {
            routeAnimationTask = Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                let count = plan.stepCount
                let duration: CFTimeInterval = 1.65
                let started = CACurrentMediaTime()
                var index = 0
                while index < count {
                    guard !Task.isCancelled, self.routePreparationRevision == revision,
                          self.routeStyleSignature == styleSignature,
                          self.routeDataSignature == dataSignature else { return }
                    let timed = Int(ceil(min(1, (CACurrentMediaTime() - started) / duration) * Double(count)))
                    let upper = min(count, max(index + 1, timed))
                    self.applyRouteSteps(plan, from: index, to: upper, theme: theme, on: mapView)
                    self.routeRenderRevision &+= 1
                    index = upper
                    if index < count {
                        let remaining = duration - (CACurrentMediaTime() - started)
                        if remaining > 0 {
                            try? await Task.sleep(nanoseconds: min(33_000_000, UInt64(remaining * 1_000_000_000)))
                        }
                    }
                }
                self.publishPlainViewportSnapshotIfPossible(on: mapView)
            }
        }

        private func clearRouteBatch(on mapView: MKMapView) {
            routePreparationTask?.cancel()
            routePreparationRevision &+= 1
            routeState.clear()
            routeSurfaceRenderer?.setNeedsDisplay()
            routeRenderRevision &+= 1
        }

        /// Advance only the visible event index. No per-edge MapKit objects
        /// are created, removed or registered during animation or camera moves.
        private func applyRouteSteps(_ plan: RouteRenderPlan, from first: Int, to last: Int,
                                     theme: AppTheme, on mapView: MKMapView) {
            let timing = MapPerformanceProbe.begin("main.routeAnimationStep")
            defer { MapPerformanceProbe.end(timing) }
            let changed = plan.changedBounds(from: first, to: last)
            routeState.advance(to: last)
            guard !changed.isNull, let palette = routeState.snapshot()?.palette else { return }
            let scale = Double(mapView.bounds.width) / max(1, mapView.visibleMapRect.width)
            let padding = Double(palette.maximumScreenWidth + 2) / max(Double.leastNonzeroMagnitude, scale)
            routeSurfaceRenderer?.setNeedsDisplay(changed.insetBy(dx: -padding, dy: -padding))
        }

        private func resetRoutePresentation() {
            routeSurface = nil
            routeSurfaceRenderer = nil
            routeState.clear()
        }

        private func ensureRouteSurface(for bounds: MKMapRect, on mapView: MKMapView) {
            guard !bounds.isNull, !bounds.isEmpty else { return }
            if let surface = routeSurface, surface.boundingMapRect.contains(bounds) { return }
            let timing = MapPerformanceProbe.begin("main.registerRouteSurface")
            defer { MapPerformanceProbe.end(timing) }
            let old = routeSurface
            let surface = PersistentRouteOverlay(state: routeState, contentBounds: bounds)
            routeSurface = surface
            mapView.addOverlay(surface, level: .aboveLabels)
            if let old { mapView.removeOverlay(old) }
        }

        private func publishStatsTarget(_ stats: WalkStats) {
            guard displayedStats != stats else { return }
            displayedStats = stats
            let callback = onAnimatedStatsChanged
            DispatchQueue.main.async {
                callback(stats)
            }
        }



        /// 経路だけビューで現在画面に見えている「実際の線」を共有用に切り出す。
        /// 座標は変形せず、画面座標へ正規化するだけなので、表示中の形状と一致する。
        func publishPlainViewportSnapshotIfPossible(on mapView: MKMapView) {
            let timing = MapPerformanceProbe.begin("main.shareProjection")
            defer { MapPerformanceProbe.end(timing) }
            guard displayMode == .routesOnly,
                  remixOverlay == nil,
                  mapView.bounds.width > 1,
                  mapView.bounds.height > 1 else { return }

            let bounds = mapView.bounds
            let rect = mapView.visibleMapRect
            let key = "\(rect.origin.x)|\(rect.origin.y)|\(rect.width)|\(rect.height)|\(bounds)|\(routeRenderRevision)|\(liveRouteSignature ?? 0)|\(latestDataSignature)"
            guard plainSnapshotKey != key else { return }
            plainSnapshotKey = key
            var visible: [RemixViewportSnapshot.Segment] = []
            func append(id: String, start a: CLLocationCoordinate2D, end b: CLLocationCoordinate2D,
                        frequency: Int, estimated: Bool) {
                let start = mapView.convert(a, toPointTo: mapView)
                let end = mapView.convert(b, toPointTo: mapView)
                let lineBounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                    width: max(1, abs(start.x - end.x)), height: max(1, abs(start.y - end.y)))
                    .insetBy(dx: -4, dy: -4)
                guard lineBounds.intersects(bounds) else { return }
                visible.append(.init(id: id,
                    start: CGPoint(x: start.x / bounds.width, y: start.y / bounds.height),
                    end: CGPoint(x: end.x / bounds.width, y: end.y / bounds.height),
                    frequency: frequency, isEstimated: estimated))
            }
            if let frame = routeState.snapshot() {
                let padding = 12 * rect.width / Double(bounds.width)
                for index in frame.plan.visibleIndices(in: rect.insetBy(dx: -padding, dy: -padding), step: frame.step) {
                    let segment = frame.plan.entries[index].segment
                    append(id: segment.id, start: segment.start, end: segment.end,
                        frequency: segment.frequency, estimated: segment.isEstimated)
                }
            }
            var liveIndex = 0
            for case let line as LivePolyline in mapView.overlays
                where !line.isGlowLayer && latestVisibleTransportModes.contains(line.transportMode) && line.pointCount >= 2 {
                append(id: "live:\(liveIndex)", start: line.points()[0].coordinate,
                    end: line.points()[line.pointCount - 1].coordinate, frequency: 1, estimated: false)
                liveIndex += 1
            }

            let snapshot = RemixViewportSnapshot(
                segments: visible.sorted { $0.id < $1.id },
                viewportAspectRatio: bounds.width / bounds.height
            )
            guard snapshot != lastPublishedRemixSnapshot else { return }
            lastPublishedRemixSnapshot = snapshot
            DispatchQueue.main.async { [onRemixSnapshotChanged] in
                onRemixSnapshotChanged(snapshot)
            }
        }

        private func renderedCoreSegmentIDs(on mapView: MKMapView) -> Set<String> {
            guard let frame = routeState.snapshot() else { return [] }
            return Set(frame.plan.visibleSegments(at: frame.step).map(\.id))
        }

        func updateLiveRoute(
            _ points: [GeoPoint],
            visibleTransportModes: Set<TransportMode>,
            on mapView: MKMapView
        ) {
            var hasher = Hasher()
            hasher.combine(theme.rawValue)
            for mode in visibleTransportModes.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine(mode.rawValue)
            }
            for point in points {
                hasher.combine(point.id)
                hasher.combine(point.resolvedTransportMode.rawValue)
                hasher.combine(point.pathBreakBefore)
            }
            let signature = hasher.finalize()
            guard signature != liveRouteSignature else { return }
            liveRouteSignature = signature

            let oldLiveOverlays = mapView.overlays.filter { $0 is LivePolyline }
            mapView.removeOverlays(oldLiveOverlays)
            guard points.count > 1 else { return }

            var groups: [(mode: TransportMode, points: [GeoPoint])] = []
            for pair in zip(points, points.dropFirst()) {
                guard pair.1.connects(from: pair.0) else { continue }
                let mode = pair.1.resolvedTransportMode
                if groups.last?.mode == mode, groups.last?.points.last?.id == pair.0.id {
                    groups[groups.count - 1].points.append(pair.1)
                } else {
                    groups.append((mode, [pair.0, pair.1]))
                }
            }

            for group in groups where visibleTransportModes.contains(group.mode) {
                var coordinates = group.points.map(\.coordinate)
                let line = LivePolyline(coordinates: &coordinates, count: coordinates.count)
                line.transportMode = group.mode
                mapView.addOverlay(line, level: .aboveLabels)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let timing = MapPerformanceProbe.begin("main.createOverlayRenderer")
            defer { MapPerformanceProbe.end(timing) }
            if let tile = overlay as? BackgroundTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let tint = overlay as? MapTintOverlay {
                return MapTintRenderer(overlay: tint, color: tint.color)
            }
            if let excavation = overlay as? ExcavationMaskTileOverlay {
                return ExcavationMaskRenderer(paperOverlay: excavation)
            }
            if let remix = overlay as? RouteRemixOverlay {
                return RouteRemixOverlayRenderer(overlay: remix)
            }
            if let surface = overlay as? PersistentRouteOverlay {
                let renderer = PersistentRouteRenderer(surface: surface)
                if surface === routeSurface { routeSurfaceRenderer = renderer }
                return renderer
            }
            if let line = overlay as? LivePolyline {
                let color = theme.uiRouteColor.withAlphaComponent(line.isGlowLayer ? 0.25 : 0.85).cgColor
                return LiveRouteRenderer(line: line, color: color, screenWidth: line.isGlowLayer ? 14 : 4)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

@available(iOS 18.0, *)
extension MapCanvasView.Coordinator: MKMapItemDetailViewControllerDelegate {
    func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
        finishPlaceDetails(detailViewController, dismiss: true)
    }
}

private final class MichiUserLocationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        backgroundColor = .systemBlue
        layer.cornerRadius = 10
        layer.borderWidth = 0
        layer.shadowColor = UIColor.systemBlue.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 5
        layer.shadowOffset = .zero
        displayPriority = .required
        // This is a location indicator, not an editable map pin. Keep native
        // annotation selection/tracking out of background map gestures.
        isEnabled = false
        isUserInteractionEnabled = false
        isDraggable = false
        canShowCallout = false
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("現在地", comment: "Current location indicator")
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 経路だけビューではAppleの地図タイルを一切表示せず、同じ投影・ズーム操作だけを使う。
/// MapKitが内部で残す帰属表示は、Apple地図が見えていないこのモードに限り背景で覆う。
private final class MichiMapView: MKMapView {
    private let routeOnlyAttributionCover = UIView()
    private var showsRouteOnlyAttributionCover = false
    private(set) var midnightHexMask: MidnightHexMaskView?

    func setMidnightHexSurface(_ surface: MidnightHexSurface?) {
        if let surface, let midnightHexMask, midnightHexMask.surface === surface {
            midnightHexMask.refreshViewport()
            return
        }
        midnightHexMask?.finishEntryAnimation()
        midnightHexMask?.removeFromSuperview()
        midnightHexMask = nil
        guard let surface else { return }
        let cover = MidnightHexMaskView(surface: surface, mapView: self)
        midnightHexMask = cover
        // Above the map content, below MapKit's native controls/attribution.
        // SwiftUI's existing app controls remain above the whole map view.
        insertSubview(cover, at: min(1, subviews.count))
        cover.refreshViewport()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        routeOnlyAttributionCover.translatesAutoresizingMaskIntoConstraints = false
        routeOnlyAttributionCover.isUserInteractionEnabled = false
        routeOnlyAttributionCover.isAccessibilityElement = false
        routeOnlyAttributionCover.accessibilityElementsHidden = true
        routeOnlyAttributionCover.isHidden = true
        addSubview(routeOnlyAttributionCover)
        NSLayoutConstraint.activate([
            routeOnlyAttributionCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            routeOnlyAttributionCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            routeOnlyAttributionCover.bottomAnchor.constraint(equalTo: bottomAnchor),
            routeOnlyAttributionCover.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRouteOnlyAttributionCover(visible: Bool, color: UIColor) {
        showsRouteOnlyAttributionCover = visible
        routeOnlyAttributionCover.backgroundColor = color
        routeOnlyAttributionCover.isHidden = !visible
        if visible { bringSubviewToFront(routeOnlyAttributionCover) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        midnightHexMask?.frame = bounds
        midnightHexMask?.refreshViewport()
        if showsRouteOnlyAttributionCover {
            bringSubviewToFront(routeOnlyAttributionCover)
        }
    }
}

private final class LivePolyline: MKPolyline {
    var isGlowLayer = false
    var transportMode: TransportMode = .walking
}

private final class LiveRouteRenderer: MKOverlayRenderer {
    private let line: LivePolyline
    private let color: CGColor
    private let screenWidth: CGFloat
    init(line: LivePolyline, color: CGColor, screenWidth: CGFloat) {
        self.line = line; self.color = color; self.screenWidth = screenWidth
        super.init(overlay: line)
    }
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let timing = MapPerformanceProbe.beginSampled("render.liveRoute.sample1of16")
        defer { MapPerformanceProbe.end(timing) }
        guard zoomScale.isFinite, zoomScale > 0, line.pointCount > 1 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        context.setStrokeColor(color)
        context.setLineWidth(screenWidth / zoomScale)
        context.setLineCap(.round); context.setLineJoin(.round)
        context.beginPath()
        context.move(to: point(for: line.points()[0]))
        for index in 1..<line.pointCount { context.addLine(to: point(for: line.points()[index])) }
        context.strokePath()
    }
}

private struct RemixSourceSegment {
    let id: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let frequency: Int
    let isEstimated: Bool
    let visitedAt: Date
    let transportMode: TransportMode
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func int(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    mutating func unitCGFloat() -> CGFloat {
        CGFloat(Double(next()) / Double(UInt64.max))
    }
}

private final class RouteRemixOverlay: NSObject, MKOverlay {
    struct Segment {
        let id: String
        let sourceStart: MKMapPoint
        let sourceEnd: MKMapPoint
        let targetStart: MKMapPoint
        let targetEnd: MKMapPoint
        let frequency: Int
        let isEstimated: Bool
        let transportMode: TransportMode
    }

    let segments: [Segment]
    let boundingMapRect: MKMapRect
    var progress: CGFloat = 0
    var routeColor: UIColor
    var accentColor: UIColor
    var lineScale: CGFloat
    var usesAccent: Bool
    var themeIdentifier: String
    var activeSegmentIDs: Set<String>
    var visibleTransportModes: Set<TransportMode>

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(segments: [Segment], viewport: MKMapRect, theme: AppTheme) {
        self.segments = segments
        let segmentBounds = segments.reduce(MKMapRect.null) { result, segment in
            let points = [segment.sourceStart, segment.sourceEnd, segment.targetStart, segment.targetEnd]
            let bounds = points.reduce(MKMapRect.null) { partial, point in
                partial.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            return result.union(bounds)
        }
        boundingMapRect = segmentBounds.isNull ? viewport : segmentBounds.union(viewport)
        routeColor = UIColor(theme.routeColor)
        accentColor = UIColor(theme.interactionColor)
        lineScale = theme.lineScale
        usesAccent = false
        themeIdentifier = theme.rawValue
        activeSegmentIDs = Set(segments.map(\.id))
        visibleTransportModes = Set(TransportMode.allCases)
        super.init()
    }

    func apply(theme: AppTheme) {
        routeColor = UIColor(theme.routeColor)
        accentColor = UIColor(theme.interactionColor)
        lineScale = theme.lineScale
        usesAccent = false
    }
}

private final class RouteRemixOverlayRenderer: MKOverlayRenderer {
    private var remixOverlay: RouteRemixOverlay {
        overlay as! RouteRemixOverlay
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let overlay = remixOverlay
        let progress = Double(overlay.progress)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for segment in overlay.segments.sorted(by: { $0.frequency < $1.frequency }) {
            guard overlay.activeSegmentIDs.contains(segment.id),
                  overlay.visibleTransportModes.contains(segment.transportMode) else { continue }
            let sourceCenter = MKMapPoint(
                x: (segment.sourceStart.x + segment.sourceEnd.x) / 2,
                y: (segment.sourceStart.y + segment.sourceEnd.y) / 2
            )
            let targetCenter = MKMapPoint(
                x: (segment.targetStart.x + segment.targetEnd.x) / 2,
                y: (segment.targetStart.y + segment.targetEnd.y) / 2
            )
            let center = MKMapPoint(
                x: sourceCenter.x + (targetCenter.x - sourceCenter.x) * progress,
                y: sourceCenter.y + (targetCenter.y - sourceCenter.y) * progress
            )
            let sourceDX = segment.sourceEnd.x - segment.sourceStart.x
            let sourceDY = segment.sourceEnd.y - segment.sourceStart.y
            let length = hypot(sourceDX, sourceDY)
            let sourceAngle = atan2(sourceDY, sourceDX)
            let targetAngle = atan2(
                segment.targetEnd.y - segment.targetStart.y,
                segment.targetEnd.x - segment.targetStart.x
            )
            // 端点を直線補間すると途中で線が縮むため、中心と角度だけを補間する。
            // 角度差は最短方向へ正規化し、線分長は全フレームで固定する。
            let angleDelta = atan2(sin(targetAngle - sourceAngle), cos(targetAngle - sourceAngle))
            let angle = sourceAngle + angleDelta * progress
            let halfDX = cos(angle) * length / 2
            let halfDY = sin(angle) * length / 2
            let start = MKMapPoint(x: center.x - halfDX, y: center.y - halfDY)
            let end = MKMapPoint(x: center.x + halfDX, y: center.y + halfDY)
            let segmentRect = MKMapRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(1, abs(start.x - end.x)),
                height: max(1, abs(start.y - end.y))
            )
            guard segmentRect.intersects(mapRect) else { continue }
            let startPoint = point(for: start)
            let endPoint = point(for: end)
            let alpha = min(1, 0.48 + log2(Double(segment.frequency) + 1) * 0.19)
            let baseColor = overlay.usesAccent && segment.frequency >= 3
                ? overlay.accentColor
                : overlay.routeColor
            context.setStrokeColor(baseColor.withAlphaComponent(
                segment.isEstimated ? min(alpha, 0.58) : alpha
            ).cgColor)
            let width = (1.25 + min(5.2, CGFloat(log2(Double(segment.frequency) + 1)) * 1.35))
                * overlay.lineScale / max(zoomScale, 0.000_001)
            context.setLineWidth(width)
            context.beginPath()
            context.move(to: startPoint)
            context.addLine(to: endPoint)
            context.strokePath()
        }
    }
}

private final class BackgroundTileOverlay: MKTileOverlay {
    private let tileData: Data

    init(color: UIColor) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        tileData = renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        result(tileData, nil)
    }
}

/// Theme-specific cover, revealing the Apple map near travelled streets.
/// Both covers follow the map; Midnight uses a lightweight projected layer canvas.
private final class ExcavationMaskTileOverlay: NSObject, MKOverlay {
    typealias Segment = TornPaperRenderer.Segment
    private static let sharedMaterial: PaperMaterial? = {
        guard let image = UIImage(named: "TornPaperSurface")?.cgImage else { return nil }
        return PaperMaterial(image: image)
    }()
    private static let sharedEdgeMaterial: PaperEdgeMaterial? = {
        guard let image = UIImage(named: "TornPaperFineEdge")?.cgImage else { return nil }
        return PaperEdgeMaterial(image: image)
    }()
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
    let pipeline: PaperTilePipeline?
    let hexSurface: MidnightHexSurface?
    let paperColor: CGColor
    private let paper: TornPaperRenderer?

    init(segments: [Segment], darkPaper: Bool, preparedIndex: PaperSegmentIndex? = nil) {
        if darkPaper {
            hexSurface = MidnightHexSurface(segments: segments, preparedIndex: preparedIndex)
            paper = nil
            pipeline = nil
        } else {
            hexSurface = nil
            let edge = Self.sharedEdgeMaterial
            let paper = TornPaperRenderer(segments: segments, darkPaper: false,
                material: edge == nil ? Self.sharedMaterial : nil, edgeMaterial: edge,
                segmentIndex: preparedIndex ?? PaperSegmentIndex(segments: segments))
            self.paper = paper
            pipeline = PaperTilePipeline(paper: paper, scale: UIScreen.main.scale)
        }
        paperColor = darkPaper ? UIColor(red: 0.060, green: 0.079, blue: 0.112, alpha: 1).cgColor
            : UIColor(red: 205 / 255, green: 201 / 255, blue: 194 / 255, alpha: 1).cgColor
        super.init()
    }

    func invalidate() { pipeline?.invalidate(); hexSurface?.invalidate() }
    func updateViewport(_ rect: MKMapRect, zoomScale: Double, settled: Bool = false) {
        guard zoomScale.isFinite, zoomScale > 0 else { return }
        pipeline?.updateViewport(rect, zoomScale: zoomScale)
    }
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        paper?.contains(coordinate) ?? false
    }
}

/// Draw cached native images immediately. MapKit moves this overlay with the
/// map; missing zoom levels reuse geographically aligned parents/children
/// while progressive jobs refine them, rather than exposing an empty tile.
private final class ExcavationMaskRenderer: MKOverlayRenderer {
    private let paperOverlay: ExcavationMaskTileOverlay

    init(paperOverlay: ExcavationMaskTileOverlay) {
        self.paperOverlay = paperOverlay
        super.init(overlay: paperOverlay)
        paperOverlay.pipeline?.setCallback { [weak self] rect in
            DispatchQueue.main.async { [weak self] in self?.setNeedsDisplay(rect) }
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let pipeline = paperOverlay.pipeline else { return }
        let timing = MapPerformanceProbe.begin("render.paperTiles")
        defer { MapPerformanceProbe.end(timing) }
        let level = PaperTileKey.level(zoomScale: zoomScale)
        context.saveGState()
        context.clip(to: rect(for: mapRect))
        context.interpolationQuality = .medium
        for key in PaperTileKey.covering(mapRect, level: level) {
            pipeline.request(key)
            let target = rect(for: key.rect)
            if let image = pipeline.image(for: key) {
                draw(image, in: target, context: context)
                continue
            }
            var ancestor = key, fallback: CGImage?
            for _ in 0..<min(3, key.z) {
                ancestor = ancestor.parent
                if let image = pipeline.image(for: ancestor) {
                    let divisions = 1 << (key.z - ancestor.z)
                    let side = Double(image.width) / Double(divisions)
                    fallback = image.cropping(to: CGRect(x: Double(key.x % divisions) * side,
                        y: Double(key.y % divisions) * side, width: side, height: side))
                    if fallback != nil { break }
                }
            }
            if let fallback {
                draw(fallback, in: target, context: context)
            } else {
                context.setFillColor(paperOverlay.paperColor)
                context.fill(target)
                drawCachedChildren(of: key, depth: 2, context: context)
            }
        }
        context.restoreGState()
    }

    private func drawCachedChildren(of key: PaperTileKey, depth: Int, context: CGContext) {
        guard depth > 0, key.z < 22 else { return }
        for y in 0..<2 { for x in 0..<2 {
            let child = PaperTileKey(x: key.x * 2 + x, y: key.y * 2 + y, z: key.z + 1)
            if let image = paperOverlay.pipeline?.image(for: child) {
                draw(image, in: rect(for: child.rect), context: context)
            } else { drawCachedChildren(of: child, depth: depth - 1, context: context) }
        }}
    }

    private func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

private final class MapTintOverlay: NSObject, MKOverlay {
    let color: UIColor
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world

    init(color: UIColor) {
        self.color = color
        super.init()
    }
}

private final class MapTintRenderer: MKOverlayRenderer {
    private let color: UIColor

    init(overlay: MKOverlay, color: UIColor) {
        self.color = color
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect(for: mapRect))
    }
}
