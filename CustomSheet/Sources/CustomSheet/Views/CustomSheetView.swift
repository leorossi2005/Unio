//
//  CustomSheetView.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 13/06/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

enum DraggerValues {
    static var width: CGFloat {
        if #available(iOS 27, *) {
            return 60
        } else {
            return 36
        }
    }
    
    static var height: CGFloat {
        if #available(iOS 27, *) {
            return 4
        } else {
            return 5
        }
    }
    
    static var topPadding: CGFloat {
        if #available(iOS 27, *) {
            return 6
        } else {
            return 5
        }
    }
}

// MARK: - Focus restore
private struct GrabberFocusRestorer: ViewModifier {
    let token: Int
    
    @AccessibilityFocusState private var isFocused: Bool
    
    func body(content: Content) -> some View {
        content
            .accessibilityFocused($isFocused)
            .task(id: token) {
                guard token > 0, UIAccessibility.isVoiceOverRunning else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
                if !isFocused { isFocused = true }
            }
    }
}

private struct SheetContentTopKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

@MainActor
private final class DetentSuppressionBox {
    var target: CustomSheetDetent? = nil
}

struct CustomSheet<Content: View>: View {
    @Binding var isPresented: Bool
    var detents: [CustomSheetDetent]
    
    @State private var manager: GlobalSheetManager
    @State private var fold: FoldStateStore
    @State private var activeDetents: [CustomSheetDetent]
    
    @State var sheetShapeRadii: SheetCornerRadii
    @State private var isAtMax: Bool
    
    // Gesture & Layout States
    @State private var enableBackground: Bool
    @State private var isTrackingLargeShrink: Bool = false
    @State private var committedLarge: CGFloat? = nil
    @State private var committedMedium: CGFloat? = nil
    @State private var baseHeight: CGFloat
    @State private var width: CGFloat
    @State private var hasMounted: Bool = false
    @State private var grabberRestoreToken: Int = 0
    
    @State private var dragY: CGFloat = .zero
    
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sheetPadding: SheetPadding
    
    @State private var offset: CGFloat = .zero
    @State private var cornerAnimationDuration: TimeInterval = 0.2
    @State private var useSpringForCorners: Bool = false
    @State private var divisionLayout = HingeDivisionLayout()
    @State private var canAnimateHingeTransition: Bool = false
    @State private var isHorizontalContainer: Bool = false
    @State private var suppressedDetent = DetentSuppressionBox()
    @State private var glassRef = GlassContainerRef()
    
    private var activeContainerWidth: CGFloat {
        width > 0 ? width : fold.windowSize.width
    }

    private var defaultPadding: SheetPadding {
        SheetPadding.defaultPadding(
            bottomSafeArea: fold.bottomSafeArea,
            containerWidth: activeContainerWidth
        )
    }

    private var finalPadding: SheetPadding {
        SheetPadding.finalPadding(
            bottomSafeArea: fold.bottomSafeArea,
            containerWidth: activeContainerWidth,
            hasHinge: fold.hasHinge
        )
    }
    
    private static var largeTopCornerRadius: CGFloat {
        UIDevice.isIpad ? 32 : 38
    }

    private var effectiveDetents: [CustomSheetDetent] {
        manager.locked ? [manager.selectedDetent] : detents
    }

    private var usesLegacyMediumToLargeProgress: Bool {
        if #unavailable(iOS 26), !UIDevice.isIpad {
            return horizontalSizeClass != .regular
        }
        return false
    }

    private func maxSheetWidth(for containerWidth: CGFloat, finalSidePadding: CGFloat) -> CGFloat {
        if UIDevice.isIpad {
            if SheetPadding.isIpadCompactMode(containerWidth: containerWidth) {
                return containerWidth
            }
            return SheetPadding.ipadCenteredMaxWidth
        }
        let size = fold.windowSize
        let portraitWidth = min(size.width, size.height)
        let effectiveWidth = portraitWidth - (finalSidePadding * 2)
        return effectiveWidth > 0 ? effectiveWidth : SheetPadding.ipadCenteredMaxWidth
    }

    private var maxSheetWidth: CGFloat {
        maxSheetWidth(for: activeContainerWidth, finalSidePadding: finalPadding.side)
    }
    
    let content: Content
    
    init(
        isPresented: Binding<Bool>,
        detents: [CustomSheetDetent],
        manager: GlobalSheetManager?,
        fold providedFold: FoldStateStore? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self._isPresented = isPresented
        self.detents = detents
        
        let fold = providedFold ?? FoldStateStore()
        self._fold = State(initialValue: fold)
        
        let safeDefault = detents.min(by: { $0.value(fold: fold) < $1.value(fold: fold) }) ?? .small
        let initialManager: GlobalSheetManager
        
        if let providedManager = manager {
            if !detents.contains(providedManager.selectedDetent) {
                providedManager.setDetent(safeDefault)
            }
            initialManager = providedManager
        } else {
            initialManager = GlobalSheetManager(initialDetent: safeDefault)
        }
        
        if providedFold != nil { initialManager.fold = fold }
        self._manager = State(initialValue: initialManager)
        self._activeDetents = State(initialValue: detents)
        
        let startingDetent = initialManager.selectedDetent
        if !initialManager.hasMountedLiveMetrics {
            initialManager.liveMetrics.currentHeight = startingDetent.value(fold: fold)
        }
        
        self._baseHeight = State(initialValue: startingDetent.value(fold: fold))
        self._enableBackground = State(initialValue: startingDetent == .large)
        
        let initialWidth = fold.windowSize.width
        let initialBottomSafeArea = fold.bottomSafeArea
        let basePad = SheetPadding.defaultPadding(
            bottomSafeArea: initialBottomSafeArea,
            containerWidth: initialWidth
        )
        let initialFinalPad = SheetPadding.finalPadding(
            bottomSafeArea: initialBottomSafeArea,
            containerWidth: initialWidth,
            hasHinge: fold.hasHinge
        )
        let actualPadding = startingDetent == .large ? initialFinalPad : basePad
        self._sheetPadding = State(initialValue: actualPadding)
        
        let isLarge = (startingDetent == .large)
        self._isAtMax = State(initialValue: isLarge)
        let initialRadius: CGFloat = isLarge ? Self.largeTopCornerRadius : -1
        self._sheetShapeRadii = State(initialValue: Self.calculateRadii(
            sheetCornerRadius: initialRadius,
            padding: actualPadding,
            defaultPadding: basePad,
            isAtMax: isLarge,
            fold: fold,
            containerWidth: initialWidth
        ))
        
        self._width = State(initialValue: fold.windowSize.width)
        
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { proxy in
            let largeLive = CustomSheetDetent.large.value(
                containerHeight: proxy.size.height,
                containerWidth: proxy.size.width,
                fold: fold
            )
            let mediumLive = CustomSheetDetent.medium.value(
                containerHeight: proxy.size.height,
                containerWidth: proxy.size.width,
                fold: fold
            )
            let delta = activeDetentDelta(largeLive: largeLive, mediumLive: mediumLive)
            let height = liveHeight(delta: delta)
            let currentDetents = effectiveDetents
            let mediumStartLive = currentDetents.contains(.medium)
                ? mediumLive
                : (currentDetents.filter { $0 != .large }.map {
                    $0.value(
                        containerHeight: proxy.size.height,
                        containerWidth: proxy.size.width,
                        fold: fold
                    )
                }.min() ?? mediumLive)
            let tracksMediumToLarge = currentDetents.contains(.large)
                || isTrackingLargeShrink
                || (manager.locked && manager.selectedDetent == .large)
            let usesLegacyProgress = usesLegacyMediumToLargeProgress
            let liveDivisionLayout = computeDivisionLayout(in: proxy)
            let currentContainerWidth = proxy.size.width > 0 ? proxy.size.width : activeContainerWidth
            let currentDefaultPadding = SheetPadding.defaultPadding(
                bottomSafeArea: fold.bottomSafeArea,
                containerWidth: currentContainerWidth
            )
            let currentFinalPadding = SheetPadding.finalPadding(
                bottomSafeArea: fold.bottomSafeArea,
                containerWidth: currentContainerWidth,
                hasHinge: fold.hasHinge
            )
            let targetMaxWidth = divisionLayout.maxWidth ?? maxSheetWidth(
                for: currentContainerWidth,
                finalSidePadding: currentFinalPadding.side
            )
            let currentIsHalfLandscape = divisionLayout.alignToLeading
            let radiiSpec = Self.makeRadiiSpec(
                defaultPadding: currentDefaultPadding,
                finalPadding: currentFinalPadding,
                fold: fold,
                containerWidth: currentContainerWidth,
                isHalfLandscape: currentIsHalfLandscape
            )
            let isCurrentlyDragging = manager.isDragging
            
            ZStack(alignment: divisionLayout.alignToLeading ? .bottomLeading : .bottom) {
                    SheetMediumToLargeDimView(
                        liveHeight: height,
                        startHeight: mediumStartLive,
                        endHeight: largeLive,
                        tracksProgress: tracksMediumToLarge,
                        isSelectedLarge: manager.selectedDetent == .large,
                        appliesDimAndScale: isPresented && hasMounted,
                        dimOpacity: usesLegacyProgress ? 0.125 : 0.2,
                        radiiSpec: radiiSpec,
                        onProgressChange: { progress, liveRadii in
                            if usesLegacyProgress {
                                manager.onLegacyScaleProgress?(progress, false)
                            }
                            glassRef.applyLiveCorners(liveRadii)
                        },
                        onLiveHeightFrame: { liveH in
                            guard !isCurrentlyDragging else { return }
                            let diff = abs(manager.liveMetrics.currentHeight - liveH)
                            let isEndpoint = abs(liveH - height) < 0.05
                            if diff > 0.5 || (isEndpoint && diff > 0.01) {
                                DispatchQueue.main.async {
                                    guard !manager.isDragging else { return }
                                    if abs(manager.liveMetrics.currentHeight - liveH) > 0.01 {
                                        manager.liveMetrics.currentHeight = liveH
                                    }
                                    if isTrackingLargeShrink && !effectiveDetents.contains(.large) && liveH <= mediumStartLive + 0.5 {
                                        isTrackingLargeShrink = false
                                    }
                                }
                            } else if isTrackingLargeShrink && !effectiveDetents.contains(.large) && liveH <= mediumStartLive + 0.5 {
                                DispatchQueue.main.async {
                                    if isTrackingLargeShrink && !effectiveDetents.contains(.large) {
                                        isTrackingLargeShrink = false
                                    }
                                }
                            }
                        }
                    )
                    .ignoresSafeArea()
                    .padding(.top, -1)
                    .padding(.horizontal, fold.hasHinge ? -8 : 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(enableBackground)
                    
                    GlassContainer(
                        radii: sheetShapeRadii,
                        animationDuration: cornerAnimationDuration,
                        useSpring: useSpringForCorners,
                        isEnabled: !enableBackground,
                        isDragging: manager.isDragging,
                        fixedContentHeight: largeLive,
                        horizontalContentExpansion: (fold.hasHinge && (fold.isClosed || fold.splitScreen.isSplit)) ? 4 : 0,
                        glassRef: glassRef,
                        onLiveHeightChange: nil
                    ) {
                        mainSheet(maxHeight: largeLive, mediumHeight: mediumLive)
                            .ignoresSafeArea(.all, edges: .vertical)
                    }
                    .overlay {
                        SheetDragger(
                            isAtLargeDetent: manager.selectedDetent == .large,
                            onDrag: { translationY, _ in
                                handleDragUpdating(value: translationY, state: &self.dragY)
                            },
                            onEnded: { translationY, predictedEndTranslation in
                                handleDragEnded(translationY, predictedEndTranslation)
                            }
                        )
                        .allowsHitTesting(false)
                    }
                    .frame(height: height)
                    .frame(maxWidth: targetMaxWidth)
                    .offset(y: (isPresented && hasMounted) ? -offset : height + defaultPadding.bottom)
                    .modifier(ClampedPadding(padding: sheetPadding, hasHinge: fold.hasHinge))
                    .opacity(isPresented ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .environment(manager)
                .animation(.smooth(duration: 0.3), value: isPresented)
                .animation(.smooth(duration: 0.3), value: hasMounted)
                .onChange(of: enableBackground) { _, newValue in
                    manager.onBackgroundToggle?(newValue)
                }
                .onAppear {
                    manager.onBackgroundToggle?(enableBackground)
                    manager.onLargeDetentToggle?(manager.selectedDetent == .large)
                }
                .monitorFoldState(fold)
            .onChange(of: proxy.size, initial: true) { oldSize, newSize in
                fold.syncWindowMetrics()
                let isHorizontal = fold.isScreenLandscape(fallbackSize: newSize)
                let orientationChanged = oldSize != newSize && isHorizontalContainer != isHorizontal
                let compactModeChanged = oldSize != newSize
                    && SheetPadding.isIpadCompactMode(containerWidth: oldSize.width)
                    != SheetPadding.isIpadCompactMode(containerWidth: newSize.width)
                if orientationChanged {
                    canAnimateHingeTransition = false
                }
                isHorizontalContainer = isHorizontal
                handleContainerResize(newSize)
                if orientationChanged || compactModeChanged {
                    let isLarge = (manager.selectedDetent == .large)
                    let targetPadding = isLarge ? finalPadding : defaultPadding
                    if !manager.isDragging {
                        sheetPadding = targetPadding
                    }
                    setSheetShape(
                        sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                        isAtMax: isLarge,
                        padding: targetPadding
                    )
                }
            }
            .onChange(of: largeLive) { _, _ in
                syncDetent(.large, containerHeight: proxy.size.height, containerWidth: proxy.size.width)
            }
            .onChange(of: mediumLive) { _, _ in
                syncDetent(.medium, containerHeight: proxy.size.height, containerWidth: proxy.size.width)
            }
            .onChange(of: liveDivisionLayout, initial: true) { _, newLayout in
                let state = fold.state
                let shouldAnimate = canAnimateHingeTransition
                    && fold.isScreenLandscape(fallbackSize: proxy.size)
                    && !fold.isClosed
                    && (state == .partiallyOpen || state == .fullyOpen)
                canAnimateHingeTransition = false

                let applyLayoutAndShape = {
                    divisionLayout = newLayout
                    let isLarge = (manager.selectedDetent == .large)
                    let targetPadding = isLarge ? finalPadding : defaultPadding
                    setSheetShape(
                        sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                        isAtMax: isLarge,
                        padding: targetPadding
                    )
                }

                if shouldAnimate {
                    withAnimation(.smooth(duration: 0.3)) {
                        applyLayoutAndShape()
                    }
                } else {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        applyLayoutAndShape()
                    }
                }
            }
            .onChange(of: fold.state) { oldState, newState in
                let isOpenStateSwap =
                    (oldState == .fullyOpen && newState == .partiallyOpen) ||
                    (oldState == .partiallyOpen && newState == .fullyOpen)
                canAnimateHingeTransition = isOpenStateSwap && isHorizontalContainer

                let applyFoldUpdate = {
                    let isLarge = (manager.selectedDetent == .large)
                    let targetPadding = isLarge ? currentFinalPadding : currentDefaultPadding
                    if !manager.isDragging {
                        sheetPadding = targetPadding
                    }
                    setSheetShape(
                        sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                        isAtMax: isLarge,
                        padding: targetPadding
                    )
                    if (manager.selectedDetent == .large || manager.selectedDetent == .medium) && !manager.isDragging {
                        syncDetent(manager.selectedDetent, containerHeight: proxy.size.height, containerWidth: proxy.size.width)
                    } else {
                        resyncLargeReference()
                    }
                }

                if oldState == .closed || newState == .closed {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        applyFoldUpdate()
                    }
                    manager.onLargeDetentToggle?(manager.selectedDetent == .large)
                } else {
                    applyFoldUpdate()
                }
            }
            .onChange(of: fold.splitScreen) { _, _ in
                let isLarge = (manager.selectedDetent == .large)
                let targetPadding = isLarge ? currentFinalPadding : currentDefaultPadding
                if !manager.isDragging {
                    sheetPadding = targetPadding
                }
                setSheetShape(
                    sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                    isAtMax: isLarge,
                    padding: targetPadding
                )
                manager.onLargeDetentToggle?(isLarge)
            }
            .onChange(of: fold.bottomSafeArea) { _, _ in
                let isLarge = (manager.selectedDetent == .large)
                let targetPadding = isLarge ? currentFinalPadding : currentDefaultPadding
                let applyBottomSafeAreaUpdate = {
                    if !manager.isDragging {
                        sheetPadding = targetPadding
                    }
                    setSheetShape(
                        sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                        isAtMax: isLarge,
                        padding: targetPadding
                    )
                    if (isLarge || manager.selectedDetent == .medium) && !manager.isDragging {
                        syncDetent(
                            manager.selectedDetent,
                            containerHeight: proxy.size.height,
                            containerWidth: proxy.size.width,
                            animated: hasMounted
                        )
                    } else {
                        resyncLargeReference()
                    }
                }
                if hasMounted {
                    withAnimation(.smooth(duration: 0.25)) {
                        applyBottomSafeAreaUpdate()
                    }
                } else {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        applyBottomSafeAreaUpdate()
                    }
                }
            }
        }
        .onChange(of: isPresented) { _, newValue in
            if !newValue {
                if effectiveDetents.contains(.large) || manager.selectedDetent == .large || isAtMax {
                    isTrackingLargeShrink = true
                }
                let lowestDetent = effectiveDetents.min(by: { $0.value(fold: fold) < $1.value(fold: fold) }) ?? .small
                manager.setDetent(lowestDetent)
            }
        }
        .onChange(of: manager.selectedDetent) { oldValue, newValue in
            manager.previousDetent = oldValue
            manager.onLargeDetentToggle?(newValue == .large)
            if oldValue != .large && !effectiveDetents.contains(.large) {
                isTrackingLargeShrink = false
            }
            if suppressedDetent.target == newValue {
                suppressedDetent.target = nil
                return
            }
            suppressedDetent.target = nil
            enableBackground = newValue == .large
            resyncLargeReference()
            let atMax = newValue == .large
            isAtMax = atMax
            
            cornerAnimationDuration = newValue == .large ? 0.55 : 0.35
            useSpringForCorners = true
            
            withAnimation(.interpolatingSpring(
                mass: 1.0,
                stiffness: 200,
                damping: 30,
                initialVelocity: 0
            )) {
                let targetPadding = newValue == .large ? finalPadding : defaultPadding
                sheetPadding = targetPadding
                
                baseHeight = newValue.value(fold: fold)
                dragY = 0
                offset = 0
            }
        }
        .onChange(of: manager.locked) { _, isLocked in
            if isLocked {
                activeDetents = [manager.selectedDetent]
            } else {
                activeDetents = detents
            }
        }
        .onChange(of: detents) { oldDetents, newDetents in
            if newDetents.contains(.large) {
                isTrackingLargeShrink = false
            } else if oldDetents.contains(.large) && !manager.isDragging &&
                        (manager.selectedDetent == .large || manager.previousDetent == .large || isAtMax) &&
                        manager.liveMetrics.currentHeight > CustomSheetDetent.medium.value(fold: fold) + 0.5 {
                isTrackingLargeShrink = true
            }
            if !manager.locked {
                activeDetents = newDetents
                
                if !newDetents.contains(manager.selectedDetent) {
                    let safeFallback = newDetents.min(by: { $0.value(fold: fold) < $1.value(fold: fold) }) ?? .small
                    manager.setDetent(safeFallback)
                }
            }
        }
        .onAppear {
            manager.hasMountedLiveMetrics = true
            manager.fold = fold
            fold.syncWindowMetrics()
            resyncLargeReference()
            manager.actionDismiss = {
                isPresented = false
            }
            let isLarge = (manager.selectedDetent == .large)
            let targetPadding = isLarge ? finalPadding : defaultPadding
            sheetPadding = targetPadding
            setSheetShape(
                sheetCornerRadius: isLarge ? Self.largeTopCornerRadius : -1,
                isAtMax: isLarge,
                padding: targetPadding
            )
        }
        .onDisappear {
            manager.hasMountedLiveMetrics = false
        }
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            hasMounted = true
        }
    }
    
    private func mainSheet(maxHeight: CGFloat, mediumHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
                .opacity(enableBackground ? 1 : 0)
                .ignoresSafeArea()
            
            content
                .environment(\.sheetLargeHeight, maxHeight)
                .environment(\.sheetMediumHeight, mediumHeight)
                .scrollDismissesKeyboard(.interactively)
                .modify { view in
                    if fold.hasHinge {
                        view.frame(maxWidth: .infinity)
                    } else {
                        view.frame(width: min(maxSheetWidth, width))
                    }
                }
                .frame(maxHeight: maxHeight, alignment: .top)
                .anchorPreference(key: SheetContentTopKey.self, value: .top) { $0 }
        }
        .overlayPreferenceValue(SheetContentTopKey.self) { topAnchor in
            if let topAnchor {
                GeometryReader { proxy in
                    let _y = proxy[topAnchor].y
                    sheetHandle
                        .frame(width: proxy.size.width, alignment: .top)
                        .offset(y: _y)
                }
                .ignoresSafeArea()
            }
        }
    }
    
    @ViewBuilder
    private var sheetHandle: some View {
        if !manager.locked && effectiveDetents.count > 1 {
            let sorted = effectiveDetents.sorted(by: { $0.value(fold: fold) < $1.value(fold: fold) })
            let isAtMax = manager.selectedDetent == sorted.last
            
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: DraggerValues.width, height: DraggerValues.height)
                    .contentShape(.hoverEffect, Capsule())
                    .hoverEffect(.highlight)
                    .padding(.top, DraggerValues.topPadding)
            }
            .frame(width: max(80, DraggerValues.width + 44), height: 32, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(sorted: sorted)
            }
            .accessibilityElement()
            .accessibilitySortPriority(100)
            .accessibilityLabel(Text(String(localized: .sheetDragger)))
            .accessibilityValue(detentAccessibilityValue(for: manager.selectedDetent))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(
                isAtMax
                    ? Text(String(localized: .sheetTapToCollapse))
                    : Text(String(localized: .sheetTapToExpand))
            )
            .modifier(GrabberFocusRestorer(token: grabberRestoreToken))
        }
    }

    // MARK: - Handle Actions
    private func handleTap(sorted: [CustomSheetDetent]) {
        guard let currentIndex = sorted.firstIndex(of: manager.selectedDetent) else { return }
        let nextIndex = (currentIndex + 1) < sorted.count ? (currentIndex + 1) : 0
        let newDetent = sorted[nextIndex]
        
        // Uscendo da .large col grabber, il focus VoiceOver deve restare sul grabber
        let leavingLarge = manager.selectedDetent == .large
        manager.keepAccessibilityFocusOnLargeExit = leavingLarge
        manager.setDetent(newDetent)
        if leavingLarge { grabberRestoreToken += 1 }
    }

    private func detentAccessibilityValue(for detent: CustomSheetDetent) -> Text {
        Text(detentAccessibilityString(for: detent))
    }

    private func detentAccessibilityString(for detent: CustomSheetDetent) -> String {
        switch detent {
        case .small:  return String(localized: .sheetSmall)
        case .medium: return String(localized: .sheetMedium)
        case .large:  return String(localized: .sheetLarge)
        }
    }
    
    // MARK: - Drag Logic
    func rubberBandDistance(offset: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return 0 }
        
        let coefficient: CGFloat = 0.55
        return (1.0 - (1.0 / ((offset * coefficient / dimension) + 1.0))) * dimension
    }
    
    private func handleDragUpdating(value: CGFloat, state: inout CGFloat) {
        if cornerAnimationDuration != 0.2 { cornerAnimationDuration = 0.2 }
        if useSpringForCorners { useSpringForCorners = false }
        let largeValue = CustomSheetDetent.large.value(fold: fold)
        let mediumValue = CustomSheetDetent.medium.value(fold: fold)
        
        if !manager.isDragging {
            if isTrackingLargeShrink {
                isTrackingLargeShrink = false
            }
            if manager.selectedDetent == .large && baseHeight != largeValue {
                baseHeight = largeValue
                committedLarge = largeValue
            }
            manager.isDragging = true
            manager.onDragToggle?(true)
        }
        
        if manager.selectedDetent == .large {
            if value < 0 {
                if !isAtMax || !enableBackground {
                    isAtMax = true
                    enableBackground = true
                }
                if state != 0 { state = 0 }
                return
            }
        }
        
        let predictedHeight = baseHeight - value
        if isTrackingLargeShrink {
            isTrackingLargeShrink = false
        }
        
        let currentDetents = effectiveDetents.sorted { $0.value(fold: fold) < $1.value(fold: fold) }
        guard let first = currentDetents.first, let last = currentDetents.last else { return }
        let minDetent = first.value(fold: fold)
        let maxDetent = last.value(fold: fold)
        
        var newOffset: CGFloat = 0
        if predictedHeight >= minDetent && predictedHeight <= maxDetent {
            state = value
            newOffset = 0
        } else if predictedHeight > maxDetent {
            let excess = predictedHeight - maxDetent
            let dampedExcess = rubberBandDistance(offset: excess, dimension: maxDetent - maxDetent * 0.75)
            state = baseHeight - (maxDetent + dampedExcess)
            newOffset = 0
        } else if predictedHeight < minDetent {
            let excess = minDetent - predictedHeight
            let dampedExcess = rubberBandDistance(offset: excess, dimension: maxDetent - maxDetent * 0.75)
            state = baseHeight - minDetent
            newOffset = -dampedExcess
        }
        if offset != newOffset { offset = newOffset }
        
        let liveDragHeight = max(0, baseHeight - state)
        if abs(manager.liveMetrics.currentHeight - liveDragHeight) > 0.01 {
            manager.liveMetrics.currentHeight = liveDragHeight
        }
        
        let effectiveHeight = (baseHeight - state) + offset
        
        let hasLargeDetent = currentDetents.contains(.large)
        let startPaddingHeight = currentDetents.contains(.medium) ? mediumValue : minDetent

        if hasLargeDetent && largeValue > startPaddingHeight {
            let newPadding: SheetPadding
            if effectiveHeight >= startPaddingHeight && effectiveHeight <= largeValue {
                let rawProgress = (effectiveHeight - startPaddingHeight) / (largeValue - startPaddingHeight)
                let progress = min(max(rawProgress, 0), 1)
                newPadding = .init(
                    side: defaultPadding.side - ((defaultPadding.side - finalPadding.side) * progress),
                    bottom: defaultPadding.bottom - ((defaultPadding.bottom - finalPadding.bottom) * progress)
                )
            } else if effectiveHeight > largeValue {
                newPadding = finalPadding
            } else {
                newPadding = defaultPadding
            }
            if sheetPadding != newPadding { sheetPadding = newPadding }
        } else if !hasLargeDetent && sheetPadding != defaultPadding {
            sheetPadding = defaultPadding
        }
        
        let backgroundThreshold = currentDetents.contains(.medium)
            ? max(largeValue * 0.8, mediumValue + max(0, largeValue - mediumValue) * 0.35)
            : largeValue * 0.8
        let shouldEnableBackground = hasLargeDetent && effectiveHeight > backgroundThreshold
        let currentlyAtMax = hasLargeDetent && (largeValue > startPaddingHeight ? effectiveHeight >= largeValue : manager.selectedDetent == .large)

        let backgroundChanged = enableBackground != shouldEnableBackground
        let maxChanged = isAtMax != currentlyAtMax
        
        if backgroundChanged || maxChanged {
            enableBackground = shouldEnableBackground
            isAtMax = currentlyAtMax
        }
    }
    
    private func handleDragEnded(_ value: CGFloat, _ predictedEndTranslation: CGFloat) {
        cornerAnimationDuration = 0.2
        useSpringForCorners = false
        
        if manager.selectedDetent == .large {
            if value < 0 {
                resyncLargeReference()
                manager.isDragging = false
                manager.onDragToggle?(false)
                isAtMax = true
                enableBackground = true
                withAnimation(.interpolatingSpring(
                    mass: 1.0,
                    stiffness: 300,
                    damping: 25,
                    initialVelocity: 0
                )) {
                    baseHeight = CustomSheetDetent.large.value(fold: fold)
                    dragY = 0
                    offset = 0
                    sheetPadding = finalPadding
                }
                return
            }
        }
        
        let currentDetents = effectiveDetents.sorted { $0.value(fold: fold) < $1.value(fold: fold) }
        let rawPredictedHeight = baseHeight - value
        
        guard let minDetent = currentDetents.first, let maxDetent = currentDetents.last else { return }
        
        var effectiveTranslation = rawPredictedHeight
        
        if rawPredictedHeight > maxDetent.value(fold: fold) {
            let excess = rawPredictedHeight - maxDetent.value(fold: fold)
            let dampedExcess = rubberBandDistance(offset: excess, dimension: maxDetent.value(fold: fold) - maxDetent.value(fold: fold) * 0.75)
            effectiveTranslation = maxDetent.value(fold: fold) + dampedExcess
        }
        else if rawPredictedHeight < minDetent.value(fold: fold) {
            effectiveTranslation = minDetent.value(fold: fold)
        }
        
        let currentH = effectiveTranslation
                
        let predictedTranslation = predictedEndTranslation
        let predictedHeight = baseHeight - predictedTranslation
        var target = currentDetents.min(by: { abs($0.value(fold: fold) - predictedHeight) < abs($1.value(fold: fold) - predictedHeight) }) ?? .small
        
        if currentH < minDetent.value(fold: fold) || rawPredictedHeight < minDetent.value(fold: fold) {
            target = minDetent
        } else if currentH > maxDetent.value(fold: fold) {
            target = maxDetent
        }
        
        let isGoingDown = target.value(fold: fold) < currentH
        
        let projectedDelta = predictedTranslation - value
        let baseVelocityPerSecond = -(projectedDelta * (6.0 / 0.994))
        
        var boostFactor: CGFloat = 1.0
        
        if !isGoingDown && currentH >= minDetent.value(fold: fold) && currentH <= maxDetent.value(fold: fold) {
            let distanceToMove = abs(target.value(fold: fold) - currentH)
            let maxDistance = maxDetent.value(fold: fold) - minDetent.value(fold: fold)
            if maxDistance > 0 {
                boostFactor = 1.0 + 2.0 * (distanceToMove / maxDistance)
            }
        }
        
        let boostedVelocityPerSecond = baseVelocityPerSecond * boostFactor
        
        let visualStartH = baseHeight - dragY
        let distanceToTarget: CGFloat = target.value(fold: fold) - visualStartH
        let relativeVelocity = abs(distanceToTarget) > 1 ? boostedVelocityPerSecond / distanceToTarget : 0
        
        var limit: CGFloat = isGoingDown ? manager.selectedDetent == .large ? 30 : 45 : 45
        if currentH > maxDetent.value(fold: fold) {
            limit = 0
        }
        
        isAtMax = (target == .large)
        enableBackground = (target == .large)
        resyncLargeReference()
        manager.isDragging = false
        manager.onDragToggle?(false)
        if manager.selectedDetent != target {
            suppressedDetent.target = target
        }
        manager.setDetent(target)
        
        withAnimation(.interpolatingSpring(
            mass: 1.0,
            stiffness: 300,
            damping: 25,
            initialVelocity: min(max(relativeVelocity, -limit), limit)
        )) {
            let targetPadding = target == .large ? finalPadding : defaultPadding
            sheetPadding = targetPadding
            baseHeight = target.value(fold: fold)
            dragY = 0
            offset = 0
        }
    }
    
    private func activeDetentDelta(largeLive: CGFloat, mediumLive: CGFloat) -> CGFloat {
        guard !manager.isDragging else { return 0 }
        switch manager.selectedDetent {
        case .large:
            guard let committed = committedLarge else { return 0 }
            return largeLive - committed
        case .medium:
            guard let committed = committedMedium else { return 0 }
            return mediumLive - committed
        case .small:
            return 0
        }
    }

    private func liveHeight(delta: CGFloat) -> CGFloat {
        let h = baseHeight - dragY + delta
        return h.isFinite ? max(0, h) : 0
    }

    private func syncDetent(
        _ detent: CustomSheetDetent,
        containerHeight: CGFloat,
        containerWidth: CGFloat? = nil,
        animated: Bool = false
    ) {
        guard containerHeight > 0, detent == .large || detent == .medium else { return }
        let resolvedWidth = containerWidth ?? fold.windowSize.width
        let newValue = detent.value(
            containerHeight: containerHeight,
            containerWidth: resolvedWidth,
            fold: fold
        )
        let oldValue: CGFloat? = detent == .large ? committedLarge : committedMedium
        let setCommitted: (CGFloat) -> Void = { value in
            if detent == .large {
                committedLarge = value
            } else {
                committedMedium = value
            }
        }

        guard let oldValue else {
            setCommitted(newValue)
            if manager.selectedDetent == detent && !manager.isDragging {
                baseHeight = newValue
            }
            return
        }
        guard oldValue != newValue else {
            setCommitted(newValue)
            return
        }

        if manager.selectedDetent == detent && !manager.isDragging {
            if animated {
                baseHeight += newValue - oldValue
                setCommitted(newValue)
            } else {
                withTransaction(Transaction(animation: nil)) {
                    baseHeight += newValue - oldValue
                    setCommitted(newValue)
                }
            }
        } else {
            setCommitted(newValue)
        }
    }
    
    private func resyncLargeReference() {
        committedLarge = CustomSheetDetent.large.value(fold: fold)
        committedMedium = CustomSheetDetent.medium.value(fold: fold)
    }

    private func handleContainerResize(_ size: CGSize) {
        width = size.width
        syncDetent(.large, containerHeight: size.height, containerWidth: size.width)
        syncDetent(.medium, containerHeight: size.height, containerWidth: size.width)
    }

    private struct HingeDivisionLayout: Equatable {
        var alignToLeading: Bool = false
        var maxWidth: CGFloat? = nil
    }

    private func computeDivisionLayout(in proxy: GeometryProxy) -> HingeDivisionLayout {
        guard fold.splitScreen == .none,
              !fold.isWindowed(fallbackSize: proxy.size),
              fold.isScreenLandscape(fallbackSize: proxy.size),
              !fold.isClosed else {
            return HingeDivisionLayout()
        }
        if #available(iOS 27.1, *) {
            if let division = proxy.reservedRegions(kind: .division).first(where: {
                $0.isActive && $0.frame.height > $0.frame.width
            }), division.frame.minX > 0 {
                let rawMaxWidth = (proxy.size.width / 2) - finalPadding.side
                let scale = displayScale > 0 ? displayScale : 3.0
                // Snap down to the pixel grid so a .5 px midpoint does not round up by +1 px in SwiftUI layout.
                let pixelAlignedMaxWidth = floor((rawMaxWidth * scale) + 1e-6) / scale
                return HingeDivisionLayout(
                    alignToLeading: true,
                    maxWidth: pixelAlignedMaxWidth
                )
            }
        }
        return HingeDivisionLayout()
    }
    
    // MARK: - Logic
    @MainActor
    private static func calculateRadii(
        sheetCornerRadius: CGFloat = -1,
        padding: SheetPadding,
        defaultPadding: SheetPadding,
        isAtMax: Bool,
        fold: FoldStateStore,
        containerWidth: CGFloat = 0,
        isHalfLandscape: Bool = false
    ) -> SheetCornerRadii {
        let sidePad = padding.side
        let bottomPad = padding.bottom
        let isLarge = sheetCornerRadius != -1
        
        if UIDevice.isIpad {
            let isCompact: Bool
            if #available(iOS 26, *) {
                isCompact = SheetPadding.isIpadCompactMode(containerWidth: containerWidth)
            } else {
                isCompact = false
            }
            let baseRadius: CGFloat = isCompact ? 23 : 32
            let top: CGFloat = sheetCornerRadius == -1 ? baseRadius : sheetCornerRadius
            let bottom: CGFloat = (defaultPadding.bottom == 0 || padding.bottom == 0) ? 0 : baseRadius
            return .init(tl: top, tr: top, bl: bottom, br: bottom)
        }
        
        let displays = CGFloat.deviceDisplays
        let currentDisplay = (fold.isClosed || displays.count < 2)
            ? displays[0]
            : displays[1]
        let isSquareScreen = currentDisplay.main == 0
        
        if #unavailable(iOS 26) {
            let top: CGFloat = (isSquareScreen || isLarge) ? 10 : currentDisplay.main
            return .init(tl: top, tr: top, bl: 0, br: 0)
        } else {
            if isSquareScreen {
                let top: CGFloat = isLarge ? Self.largeTopCornerRadius : 19
                let bottom: CGFloat = isAtMax ? 0 : 19
                return .init(tl: top, tr: top, bl: bottom, br: bottom)
            }
            
            if fold.isClosed {
                if isLarge {
                    let topLeft: CGFloat = currentDisplay.tl
                    let topRight: CGFloat = max(0, currentDisplay.tr - sidePad)
                    let bottomLeft: CGFloat = isAtMax ? 0 : max(0, currentDisplay.bl - bottomPad)
                    let bottomRight: CGFloat = isAtMax ? 0 : max(0, currentDisplay.br - bottomPad)
                    return .init(tl: topLeft, tr: topRight, bl: bottomLeft, br: bottomRight)
                } else {
                    let topLeft: CGFloat = max(0, currentDisplay.main - sidePad)
                    let topRight: CGFloat = max(0, currentDisplay.tr - sidePad)
                    let bottomLeft: CGFloat = isAtMax ? 0 : currentDisplay.bl
                    let bottomRight: CGFloat = isAtMax ? 0 : max(0, currentDisplay.br - bottomPad)
                    return .init(tl: topLeft, tr: topRight, bl: bottomLeft, br: bottomRight)
                }
            }
            
            let useDisplayTopInLarge = fold.hasHinge
            var topLeft: CGFloat = (isLarge && !useDisplayTopInLarge) ? sheetCornerRadius : max(0, currentDisplay.tl - sidePad)
            var topRight: CGFloat = (isLarge && !useDisplayTopInLarge) ? sheetCornerRadius : max(0, currentDisplay.tr - sidePad)
            var bottomLeft: CGFloat = isAtMax ? 0 : max(0, currentDisplay.bl - bottomPad)
            var bottomRight: CGFloat = isAtMax ? 0 : max(0, currentDisplay.br - bottomPad)
            if fold.hasHinge && fold.splitScreen == .none {
                let duoLandscapeCornerRadius: CGFloat = 40
                let isLandscape = fold.isScreenLandscape()
                if isLarge {
                    if !isHalfLandscape {
                        topLeft = duoLandscapeCornerRadius
                    }
                    topRight = duoLandscapeCornerRadius
                } else if isLandscape {
                    topLeft = duoLandscapeCornerRadius
                    topRight = duoLandscapeCornerRadius
                }
                if isLandscape && !isAtMax {
                    if !isHalfLandscape {
                        bottomLeft = duoLandscapeCornerRadius
                    }
                    bottomRight = duoLandscapeCornerRadius
                }
            }

            if fold.hasHinge {
                let splitDividerBaseRadius: CGFloat = 30
                let topSplitRadius = max(0, splitDividerBaseRadius - sidePad)
                let bottomSplitRadius = max(0, splitDividerBaseRadius - max(sidePad, bottomPad))
                switch fold.splitScreen {
                case .left:
                    if isAtMax {
                        topRight = topSplitRadius
                    } else {
                        bottomRight = bottomSplitRadius
                    }
                case .right:
                    if isAtMax {
                        topLeft = topSplitRadius
                    } else {
                        bottomLeft = bottomSplitRadius
                    }
                case .none:
                    break
                }
            }

            return .init(tl: topLeft, tr: topRight, bl: bottomLeft, br: bottomRight)
        }
    }
    
    private func setSheetShape(sheetCornerRadius: CGFloat = -1, isAtMax: Bool? = nil, padding: SheetPadding? = nil) {
        if let isAtMax {
            self.isAtMax = isAtMax
        }
        let atMax = isAtMax ?? self.isAtMax
        let currentPadding = padding ?? sheetPadding
        sheetShapeRadii = Self.calculateRadii(
            sheetCornerRadius: sheetCornerRadius,
            padding: currentPadding,
            defaultPadding: defaultPadding,
            isAtMax: atMax,
            fold: fold,
            containerWidth: activeContainerWidth,
            isHalfLandscape: divisionLayout.alignToLeading
        )
    }

    @MainActor
    private static func makeRadiiSpec(
        defaultPadding: SheetPadding,
        finalPadding: SheetPadding,
        fold: FoldStateStore,
        containerWidth: CGFloat = 0,
        isHalfLandscape: Bool = false
    ) -> SheetCornerRadiiSpec {
        let startRadii = calculateRadii(
            sheetCornerRadius: -1,
            padding: defaultPadding,
            defaultPadding: defaultPadding,
            isAtMax: false,
            fold: fold,
            containerWidth: containerWidth,
            isHalfLandscape: isHalfLandscape
        )
        let endRadii = calculateRadii(
            sheetCornerRadius: Self.largeTopCornerRadius,
            padding: finalPadding,
            defaultPadding: defaultPadding,
            isAtMax: true,
            fold: fold,
            containerWidth: containerWidth,
            isHalfLandscape: isHalfLandscape
        )

        return SheetCornerRadiiSpec(
            start: startRadii,
            end: endRadii
        )
    }
}

private struct SheetCornerRadiiSpec: Equatable {
    let start: SheetCornerRadii
    let end: SheetCornerRadii

    func interpolated(progress: CGFloat) -> SheetCornerRadii {
        let clamped = min(max(progress, 0), 1)
        return .init(
            tl: start.tl + ((end.tl - start.tl) * clamped),
            tr: start.tr + ((end.tr - start.tr) * clamped),
            bl: start.bl + ((end.bl - start.bl) * clamped),
            br: start.br + ((end.br - start.br) * clamped)
        )
    }
}

private struct SheetMediumToLargeDimView: View, Animatable {
    var liveHeight: CGFloat
    let startHeight: CGFloat
    let endHeight: CGFloat
    let tracksProgress: Bool
    let isSelectedLarge: Bool
    let appliesDimAndScale: Bool
    let dimOpacity: Double
    let radiiSpec: SheetCornerRadiiSpec
    let onProgressChange: ((CGFloat, SheetCornerRadii) -> Void)?
    let onLiveHeightFrame: ((CGFloat) -> Void)?

    var animatableData: CGFloat {
        get { liveHeight }
        set { liveHeight = newValue }
    }

    static func progress(
        liveHeight: CGFloat,
        startHeight: CGFloat,
        endHeight: CGFloat,
        tracksProgress: Bool,
        isSelectedLarge: Bool
    ) -> CGFloat {
        guard tracksProgress else { return 0 }
        let span = endHeight - startHeight
        if span > 0 {
            return min(max((liveHeight - startHeight) / span, 0), 1)
        }
        return (isSelectedLarge && liveHeight >= endHeight) ? 1 : 0
    }

    var body: some View {
        let currentProgress = Self.progress(
            liveHeight: liveHeight,
            startHeight: startHeight,
            endHeight: endHeight,
            tracksProgress: tracksProgress,
            isSelectedLarge: isSelectedLarge
        )
        let dimAndScaleProgress = appliesDimAndScale ? currentProgress : 0
        let liveRadii = radiiSpec.interpolated(progress: currentProgress)
        let _ = onLiveHeightFrame?(liveHeight)
        let _ = onProgressChange?(dimAndScaleProgress, liveRadii)

        Color.black
            .opacity(dimOpacity * Double(dimAndScaleProgress))
    }
}
