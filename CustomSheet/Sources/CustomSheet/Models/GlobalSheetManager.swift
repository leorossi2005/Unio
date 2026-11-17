//
//  GlobalSheetManager.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 16/06/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

@MainActor
public enum CustomSheetDetent {
    case small, medium, large

    public func value(
        containerHeight: CGFloat,
        containerWidth: CGFloat = UIApplication.shared.windowSize.width,
        topSafeArea: CGFloat = UIApplication.shared.safeAreas.top,
        bottomSafeArea: CGFloat = UIApplication.shared.safeAreas.bottom
    ) -> CGFloat {
        value(
            containerHeight: containerHeight,
            containerWidth: containerWidth,
            topSafeArea: topSafeArea,
            bottomSafeArea: bottomSafeArea,
            fold: .shared
        )
    }

    /// Versione per-scena: usa lo store di piega della sheet che la richiede.
    func value(
        containerHeight: CGFloat,
        containerWidth: CGFloat? = nil,
        topSafeArea: CGFloat? = nil,
        bottomSafeArea: CGFloat? = nil,
        fold: FoldStateStore
    ) -> CGFloat {
        switch self {
        case .small:  return (((500 - 70) / 7) * 1.35) + 50
        case .medium:
            let baseMedium: CGFloat = 350 + 75
            guard containerHeight > 0 else { return baseMedium }
            let resolvedWidth = containerWidth ?? fold.windowSize.width
            let resolvedBottomSafeArea = bottomSafeArea ?? fold.bottomSafeArea
            let defaultBottom = SheetPadding.defaultPadding(
                bottomSafeArea: resolvedBottomSafeArea,
                containerWidth: resolvedWidth
            ).bottom
            let finalBottom = SheetPadding.finalPadding(
                bottomSafeArea: resolvedBottomSafeArea,
                containerWidth: resolvedWidth,
                hasHinge: fold.hasHinge
            ).bottom
            let largeValue = Self.large.value(
                containerHeight: containerHeight,
                containerWidth: resolvedWidth,
                topSafeArea: topSafeArea,
                bottomSafeArea: resolvedBottomSafeArea,
                fold: fold
            )
            let maxMedium = largeValue + finalBottom - defaultBottom
            return max(0, min(baseMedium, maxMedium))
        case .large:
            let resolvedTopSafeArea = topSafeArea ?? fold.topSafeArea
            let baseTopMargin = resolvedTopSafeArea > 0 ? resolvedTopSafeArea : 20
            let iphoneTopOffset: CGFloat
            if !UIDevice.isIpad {
                if #unavailable(iOS 26) {
                    iphoneTopOffset = 10
                } else if CGFloat.deviceCornerRadius == 0 {
                    if #available(iOS 27, *) {
                        iphoneTopOffset = 4
                    } else {
                        iphoneTopOffset = 10
                    }
                } else {
                    iphoneTopOffset = 0
                }
            } else {
                iphoneTopOffset = 0
            }
            let topMargin = baseTopMargin + iphoneTopOffset
            let resolvedWidth = containerWidth ?? fold.windowSize.width
            let isLandscapeScreen = fold.isScreenLandscape(
                fallbackSize: CGSize(width: resolvedWidth, height: containerHeight)
            )
            let useCompactTopPadding = fold.hasHinge &&
                (fold.isClosed || isLandscapeScreen)
            
            if UIDevice.isIpad {
                let resolvedBottomSafeArea = bottomSafeArea ?? fold.bottomSafeArea
                let ipadBottomPadding = SheetPadding.finalPadding(
                    bottomSafeArea: resolvedBottomSafeArea,
                    containerWidth: resolvedWidth,
                    hasHinge: fold.hasHinge
                ).bottom
                let hasWindowTrafficLights: Bool
                if #available(iOS 26, *) {
                    hasWindowTrafficLights = fold.isWindowed(
                        fallbackSize: CGSize(width: resolvedWidth, height: containerHeight)
                    )
                } else {
                    hasWindowTrafficLights = false
                }
                let ipadTopMargin = topMargin + (hasWindowTrafficLights ? 44 : 0)
                return containerHeight - ipadTopMargin - ipadBottomPadding
            } else {
                return containerHeight - (useCompactTopPadding ? 8 : topMargin)
            }
        }
    }

    func value(fold: FoldStateStore) -> CGFloat {
        let winSize = fold.windowSize
        return value(
            containerHeight: winSize.height,
            containerWidth: winSize.width,
            topSafeArea: fold.topSafeArea,
            bottomSafeArea: fold.bottomSafeArea,
            fold: fold
        )
    }

    public var value: CGFloat {
        value(containerHeight: UIApplication.shared.windowSize.height)
    }
}

@MainActor
@Observable
public final class SheetLiveMetrics {
    public var currentHeight: CGFloat

    public init(currentHeight: CGFloat = 0) {
        self.currentHeight = currentHeight
    }
}

@MainActor
@Observable
public class GlobalSheetManager {
    public internal(set) var isDragging: Bool = false
    public private(set) var locked: Bool = false
    public private(set) var selectedDetent: CustomSheetDetent
    public internal(set) var previousDetent: CustomSheetDetent?
    @ObservationIgnored public let liveMetrics: SheetLiveMetrics
    
    var onBackgroundToggle: ((Bool) -> Void)?
    var onLegacyScaleProgress: ((CGFloat, Bool) -> Void)?
    var onLargeDetentToggle: ((Bool) -> Void)?
    var onDragToggle: ((Bool) -> Void)?
    var actionDismiss: (() -> Void)?
    
    var keepAccessibilityFocusOnLargeExit: Bool = false
    
    /// Store di piega della scena che ospita questa sheet (impostato da CustomSheet).
    @ObservationIgnored var fold: FoldStateStore?
    /// True after the hosting sheet has mounted once so parent re-renders never clobber live height.
    @ObservationIgnored var hasMountedLiveMetrics: Bool = false
    
    /// Altezza di un detent calcolata con lo stato di piega della scena della sheet.
    /// Da usare nei contenuti al posto di `CustomSheetDetent.x.value`.
    public func value(for detent: CustomSheetDetent) -> CGFloat {
        detent.value(fold: fold ?? .shared)
    }
    
    // periphery:ignore
    public func dismiss() {
        actionDismiss?()
    }
    
    public func setDetent(_ detent: CustomSheetDetent) {
        selectedDetent = detent
    }
    
    public func setLock(_ lock: Bool) {
        locked = lock
    }
    
    public init(initialDetent: CustomSheetDetent = .small) {
        self.selectedDetent = initialDetent
        self.liveMetrics = SheetLiveMetrics(currentHeight: initialDetent.value)
    }
}
