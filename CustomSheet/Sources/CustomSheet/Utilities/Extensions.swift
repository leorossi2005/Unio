//
//  Extensions.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 14/06/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

@MainActor
extension UIApplication {
    private static weak var cachedKeyWindow: UIWindow?
    
    private var fastKeyWindow: UIWindow? {
        if let window = Self.cachedKeyWindow,
           window.isKeyWindow,
           window.windowScene?.activationState == .foregroundActive {
            return window
        }
        for scene in connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               windowScene.activationState == .foregroundActive {
                for window in windowScene.windows where window.isKeyWindow {
                    Self.cachedKeyWindow = window
                    return window
                }
            }
        }
        for scene in connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows where window.isKeyWindow {
                    Self.cachedKeyWindow = window
                    return window
                }
            }
        }
        return nil
    }
    
    public var safeAreas: UIEdgeInsets {
        fastKeyWindow?.safeAreaInsets ?? .zero
    }
    
    public var windowSize: CGRect {
        fastKeyWindow?.bounds ?? .zero
    }

    var activeWindowScene: UIWindowScene? {
        if let scene = fastKeyWindow?.windowScene {
            return scene
        }
        return connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

@MainActor
extension UIDevice {
    public static var isIpad: Bool {
        current.userInterfaceIdiom == .pad
    }
    
    public static let modelIdentifier: String = {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorModel
        }
        
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }()
}

public struct DeviceDisplayCornerRadii: Sendable, Equatable {
    public let main: CGFloat
    public let tl: CGFloat
    public let tr: CGFloat
    public let bl: CGFloat
    public let br: CGFloat

    public init(main: CGFloat, tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) {
        self.main = main
        self.tl = tl
        self.tr = tr
        self.bl = bl
        self.br = br
    }

    public init(all radius: CGFloat) {
        self.main = radius
        self.tl = radius
        self.tr = radius
        self.bl = radius
        self.br = radius
    }
}

@MainActor
extension CGFloat {
    public static let deviceCornerRadius: CGFloat = {
        if let radius = DeviceCornerRadii.all[UIDevice.modelIdentifier] {
            return radius
        }
        
        let bottomSafeArea = UIApplication.shared.safeAreas.bottom
        guard bottomSafeArea > 0 else { return 0 }
        return UIDevice.isIpad ? 18.0 : 55.0
    }()

    public static let deviceDisplays: [DeviceDisplayCornerRadii] = {
        if let displays = DeviceCornerRadii.displays[UIDevice.modelIdentifier], !displays.isEmpty {
            return displays
        }

        return [DeviceDisplayCornerRadii(all: deviceCornerRadius)]
    }()
}

// iPhone Duo
enum FoldState {
    case unknown
    case closed
    case partiallyOpen
    case fullyOpen
}

enum SplitScreen: Sendable, Equatable {
    case left
    case right
    case none

    var isSplit: Bool {
        self != .none
    }
}

@MainActor
@Observable
final class FoldStateStore {
    static let shared = FoldStateStore()
    
    private(set) var state: FoldState = .unknown
    private(set) var splitScreen: SplitScreen = .none
    private(set) var windowSafeTop: CGFloat?
    private(set) var windowSafeBottom: CGFloat?
    private(set) var windowBoundsSize: CGSize?
    private(set) var windowIsLandscape: Bool?
    private(set) var screenBoundsSize: CGSize?

    @ObservationIgnored weak var window: UIWindow? {
        didSet {
            if window !== oldValue {
                syncWindowMetrics()
            }
        }
    }

    func syncWindowMetrics() {
        guard let window else { return }
        let newTop = window.safeAreaInsets.top
        if windowSafeTop != newTop {
            windowSafeTop = newTop
        }
        let newBottom = window.safeAreaInsets.bottom
        if windowSafeBottom != newBottom {
            windowSafeBottom = newBottom
        }
        let newBounds = window.bounds.size
        if windowBoundsSize != newBounds {
            windowBoundsSize = newBounds
        }
        if let scene = window.windowScene {
            let scr = scene.screen.bounds.size
            if screenBoundsSize != scr {
                screenBoundsSize = scr
            }
            let orientation = scene.effectiveGeometry.interfaceOrientation
            let newLandscape = orientation != .unknown
                ? orientation.isLandscape
                : scr.width > scr.height
            if windowIsLandscape != newLandscape {
                windowIsLandscape = newLandscape
            }
        }
    }

    var windowSize: CGRect {
        _ = windowBoundsSize
        return window?.bounds ?? UIApplication.shared.windowSize
    }

    var topSafeArea: CGFloat {
        _ = windowSafeTop
        return window?.safeAreaInsets.top ?? UIApplication.shared.safeAreas.top
    }

    var bottomSafeArea: CGFloat {
        _ = windowSafeBottom
        return window?.safeAreaInsets.bottom ?? UIApplication.shared.safeAreas.bottom
    }

    var screenBounds: CGRect {
        _ = screenBoundsSize
        return window?.windowScene?.screen.bounds
            ?? UIApplication.shared.activeWindowScene?.screen.bounds
            ?? UIScreen.main.bounds
    }

    func isScreenLandscape(fallbackSize: CGSize? = nil) -> Bool {
        _ = windowIsLandscape
        if let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
           orientation != .unknown {
            return orientation.isLandscape
        }
        if let bounds = window?.windowScene?.screen.bounds
            ?? UIApplication.shared.activeWindowScene?.screen.bounds {
            return bounds.width > bounds.height
        }
        let size = fallbackSize ?? windowSize.size
        return size.width > size.height
    }

    func isWindowed(fallbackSize: CGSize? = nil) -> Bool {
        _ = windowBoundsSize
        let scrSize = screenBounds.size
        let sceneSize: CGSize?
        if #available(iOS 26, *) {
            sceneSize = (window?.windowScene ?? UIApplication.shared.activeWindowScene)?
                .effectiveGeometry.coordinateSpace.bounds.size
        } else {
            sceneSize = nil
        }
        let resolvedWinSize = sceneSize
            ?? window?.bounds.size
            ?? fallbackSize
            ?? UIApplication.shared.windowSize.size
        guard resolvedWinSize.width > 0, resolvedWinSize.height > 0,
              scrSize.width > 0, scrSize.height > 0 else {
            return false
        }
        return abs(resolvedWinSize.width - scrSize.width) >= 1.0
            || abs(resolvedWinSize.height - scrSize.height) >= 1.0
    }
    
    var hasHinge: Bool {
        if state != .unknown { return true }
        if UIDevice.modelIdentifier == "iPhone19,4" { return true }
        let size = windowSize
        if (size.width == 466 && size.height == 678) || (size.width == 678 && size.height == 466) {
            return true
        }
        let scr = screenBounds
        if (scr.width == 466 && scr.height == 678) || (scr.width == 678 && scr.height == 466) {
            return true
        }
        return false
    }

    var isClosed: Bool {
        if state == .closed { return true }
        if state == .partiallyOpen || state == .fullyOpen { return false }
        guard hasHinge else { return false }
        let scr = screenBounds
        return max(scr.width, scr.height) < 750
    }
    
    func update(_ newState: FoldState) {
        if state != newState { state = newState }
    }

    func updateSplitScreen(_ newSplitScreen: SplitScreen) {
        if splitScreen != newSplitScreen {
            splitScreen = newSplitScreen
        }
    }
}

@available(iOS 27.1, *)
@MainActor
private struct FoldStateMonitorModifier: ViewModifier {
    let store: FoldStateStore
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
        content
            .onHingeChange { _, context in
                let newState: FoldState

                switch context.hinge?.status {
                case .closed: newState = .closed
                case .partiallyOpen: newState = .partiallyOpen
                case .fullyOpen: newState = .fullyOpen
                default: newState = .unknown
                }

                store.update(newState)
                updateSplitScreen()
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { _, _ in
                updateSplitScreen()
            }
            .onChange(of: toolbarVerticalEdge, initial: true) { _, _ in
                updateSplitScreen()
            }
            .onChange(of: store.state, initial: true) { _, _ in
                updateSplitScreen()
            }
    }

    private func updateSplitScreen() {
        store.syncWindowMetrics()
        guard store.hasHinge,
              !store.isClosed,
              let windowScene = store.window?.windowScene ?? UIApplication.shared.activeWindowScene else {
            store.updateSplitScreen(.none)
            return
        }

        let sceneSize = windowScene.effectiveGeometry.coordinateSpace.bounds.size
        let screenSize = windowScene.screen.bounds.size
        let isSplitScreen = abs(sceneSize.width - screenSize.width) >= 1.0
            || abs(sceneSize.height - screenSize.height) >= 1.0

        guard isSplitScreen else {
            store.updateSplitScreen(.none)
            return
        }

        switch toolbarVerticalEdge {
        case .leading:
            store.updateSplitScreen(.left)
        case .trailing:
            store.updateSplitScreen(.right)
        case nil:
            store.updateSplitScreen(.none)
        }
    }
}

extension View {
    @ViewBuilder
    func modify<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> some View {
        transform(self)
    }
    
    @ViewBuilder
    func monitorFoldState(_ store: FoldStateStore) -> some View {
        if #available(iOS 27.1, *) {
            modifier(FoldStateMonitorModifier(store: store))
        } else {
            self
        }
    }
}

struct SheetPadding: Equatable, VectorArithmetic {
    var side: CGFloat
    var bottom: CGFloat

    static let ipadCenteredMaxWidth: CGFloat = 580
    static let ipadCompactWidthThreshold: CGFloat = ipadCenteredMaxWidth + (8 * 2)
    
    static var zero: SheetPadding {
        .init(side: 0, bottom: 0)
    }

    @MainActor
    static func isIpadCompactMode(containerWidth: CGFloat) -> Bool {
        if #available(iOS 26, *) {
            return UIDevice.isIpad && containerWidth > 0 && containerWidth < ipadCompactWidthThreshold
        }
        return false
    }

    @MainActor
    static func defaultPadding(bottomSafeArea: CGFloat, containerWidth: CGFloat) -> SheetPadding {
        if #available(iOS 26, *) {
            guard UIDevice.isIpad else {
                return .init(side: 8, bottom: 8)
            }
            if isIpadCompactMode(containerWidth: containerWidth) {
                return .init(side: 8, bottom: 8)
            }
            let bottom: CGFloat = bottomSafeArea > 0 ? bottomSafeArea : 8
            return .init(side: 0, bottom: bottom)
        } else {
            return .zero
        }
    }

    @MainActor
    static func finalPadding(bottomSafeArea: CGFloat, containerWidth: CGFloat, hasHinge: Bool) -> SheetPadding {
        if #available(iOS 26, *), UIDevice.isIpad {
            if isIpadCompactMode(containerWidth: containerWidth) {
                return .zero
            }
            let bottom: CGFloat = bottomSafeArea > 0 ? bottomSafeArea : 8
            return .init(side: 0, bottom: bottom)
        }
        return hasHinge ? .init(side: 8, bottom: 0) : .zero
    }
    
    static func + (lhs: SheetPadding, rhs: SheetPadding) -> SheetPadding {
        .init(side: lhs.side + rhs.side, bottom: lhs.bottom + rhs.bottom)
    }
    
    static func - (lhs: SheetPadding, rhs: SheetPadding) -> SheetPadding {
        .init(side: lhs.side - rhs.side, bottom: lhs.bottom - rhs.bottom)
    }
    
    mutating func scale(by factor: Double) {
        side *= CGFloat(factor)
        bottom *= CGFloat(factor)
    }
    
    var magnitudeSquared: Double {
        Double(side * side + bottom * bottom)
    }
}

private struct SheetLargeHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct SheetMediumHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    public var sheetLargeHeight: CGFloat? {
        get { self[SheetLargeHeightKey.self] }
        set { self[SheetLargeHeightKey.self] = newValue }
    }

    public var sheetMediumHeight: CGFloat? {
        get { self[SheetMediumHeightKey.self] }
        set { self[SheetMediumHeightKey.self] = newValue }
    }
}
