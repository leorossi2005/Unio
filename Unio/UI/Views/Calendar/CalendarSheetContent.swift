//
//  CalendarSheetContent.swift
//  Unio
//
//  Created by Leonardo Rossi on 16/06/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UnioCore
import CustomSheet

struct CalendarSheetContent: View {
    @Environment(\.sheetLargeHeight) private var sheetLargeHeight
    @Environment(\.sheetMediumHeight) private var sheetMediumHeight
    @Environment(GlobalSheetManager.self) private var sheetManager
    
    @Bindable var router: CalendarSheetRouter
    @Binding var selectedWeek: Date
    
    var body: some View {
        let windowHeight = UIApplication.shared.windowSize.height
        let largeHeight = sheetLargeHeight ?? sheetManager.value(for: .large)
        let mediumHeight = sheetMediumHeight ?? sheetManager.value(for: .medium)
        let mediumHeightHigh = mediumHeight * 1.05
        let mediumHeightLow = mediumHeight * 0.95
        let smallHeight = sheetManager.value(for: .small)
        let fadeRange: CGFloat = max(windowHeight * 0.05, 1)
        let hasLargeDetent = router.detents.contains(.large)
        
        ZStack(alignment: .top) {
            FractionDatePickerContainer(selectedWeek: $selectedWeek)
                .frame(height: smallHeight)
                .modifier(SheetBandOpacityModifier(
                    band: .small,
                    sheetManager: sheetManager,
                    hasLargeDetent: hasLargeDetent,
                    smallHeight: smallHeight,
                    mediumHeight: mediumHeight,
                    mediumHeightLow: mediumHeightLow,
                    mediumHeightHigh: mediumHeightHigh,
                    largeHeight: largeHeight,
                    fadeRange: fadeRange
                ))
                .allowsHitTesting(sheetManager.selectedDetent == .small)
                .accessibilityHidden(sheetManager.selectedDetent != .small)
            
            DatePickerContainer(selectedWeek: $selectedWeek)
                .equatable()
                .modifier(SheetBandOpacityModifier(
                    band: .medium,
                    sheetManager: sheetManager,
                    hasLargeDetent: hasLargeDetent,
                    smallHeight: smallHeight,
                    mediumHeight: mediumHeight,
                    mediumHeightLow: mediumHeightLow,
                    mediumHeightHigh: mediumHeightHigh,
                    largeHeight: largeHeight,
                    fadeRange: fadeRange
                ))
                .allowsHitTesting(sheetManager.selectedDetent == .medium)
                .accessibilityHidden(sheetManager.selectedDetent != .medium)
            
            NavigationStack {
                    if let notices = router.openAppNotices {
                       AppNoticeView(notices: notices) {
                           sheetManager.setDetent(.small)
                       }
                    } else if router.openWhatsNew {
                        WhatsNewView()
                    } else if router.openSettings {
                        Settings(tempSettings: $router.tempSettings)
                            .ignoresSafeArea(.keyboard)
                    } else if router.openAddPersonalEvent {
                        ManagePersonalEventView(selectedDate: selectedWeek, editingEvent: router.editingPersonalEvent) { newEvent in
                            if let newEvent = newEvent, router.selectedItem != nil {
                                router.selectedItem = .personal(newEvent)
                            }
                            
                            if router.selectedItem == nil {
                                sheetManager.setDetent(.small)
                            }
                            router.openAddPersonalEvent = false
                            router.editingPersonalEvent = nil
                        }
                    } else if let item = router.selectedItem {
                        CalendarItemDetailsView(item: item, internalItem: item.displayable, openAddToCalendar: router.openAddToCalendar, onDismiss: {
                            sheetManager.setDetent(.small)
                            router.selectedItem = nil
                            router.openAddToCalendar = false
                        }, onEdit: {
                            if case .personal(let event) = item {
                                router.routeToAddPersonalEvent(editing: event)
                            }
                        })
                    } else if let room = router.selectedRoom {
                        RoomDetailsView(room: room, selectedDate: selectedWeek)
                    }
                }
                .id(router.openSettings)
                .frame(height: largeHeight)
                .modifier(SheetBandOpacityModifier(
                    band: .large,
                    sheetManager: sheetManager,
                    hasLargeDetent: hasLargeDetent,
                    smallHeight: smallHeight,
                    mediumHeight: mediumHeight,
                    mediumHeightLow: mediumHeightLow,
                    mediumHeightHigh: mediumHeightHigh,
                    largeHeight: largeHeight,
                    fadeRange: fadeRange
                ))
                .allowsHitTesting(hasLargeDetent && sheetManager.selectedDetent == .large)
                .accessibilityHidden(!hasLargeDetent || sheetManager.selectedDetent != .large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private enum SheetFadeBand {
    case small
    case medium
    case large
}

private struct SheetBandOpacityModifier: ViewModifier {
    let band: SheetFadeBand
    let sheetManager: GlobalSheetManager
    let hasLargeDetent: Bool
    let smallHeight: CGFloat
    let mediumHeight: CGFloat
    let mediumHeightLow: CGFloat
    let mediumHeightHigh: CGFloat
    let largeHeight: CGFloat
    let fadeRange: CGFloat

    func body(content: Content) -> some View {
        let currentHeight = sheetManager.liveMetrics.currentHeight
        let isAnimatingDirectlyToLarge = hasLargeDetent
            && sheetManager.previousDetent == .small
            && sheetManager.selectedDetent == .large
            && !sheetManager.isDragging
        let isAnimatingDirectlyBetweenSmallAndLarge = hasLargeDetent
            && !sheetManager.isDragging
            && ((sheetManager.previousDetent == .small && sheetManager.selectedDetent == .large)
                || (sheetManager.previousDetent == .large && sheetManager.selectedDetent == .small))

        let opacity: Double
        switch band {
        case .small:
            let smallIsHidden = currentHeight > smallHeight + fadeRange || isAnimatingDirectlyToLarge
            let rawSmallOpacity = 1.0 - (Double(currentHeight - smallHeight) / Double(fadeRange))
            opacity = smallIsHidden ? 0.0 : min(max(rawSmallOpacity, 0.0), 1.0)
        case .medium:
            if isAnimatingDirectlyBetweenSmallAndLarge {
                opacity = 0.0
            } else if currentHeight <= mediumHeightLow {
                let effectiveLow = max(smallHeight + max(0, mediumHeight - smallHeight) * 0.5, mediumHeightLow)
                let effectiveLowFade = min(fadeRange, max(1, effectiveLow - smallHeight))
                if currentHeight >= effectiveLow {
                    opacity = 1.0
                } else {
                    let rawMediumOpacity = 1.0 - (Double(effectiveLow - currentHeight) / Double(effectiveLowFade))
                    opacity = min(max(rawMediumOpacity, 0.0), 1.0)
                }
            } else if !hasLargeDetent {
                opacity = 1.0
            } else {
                let gap = largeHeight - mediumHeight
                if gap <= 1 {
                    opacity = sheetManager.selectedDetent == .large ? 0.0 : 1.0
                } else {
                    let effectiveHigh = min(mediumHeightHigh, mediumHeight + gap * 0.4)
                    let effectiveFade = min(fadeRange, max(1, gap * 0.5))
                    if currentHeight <= effectiveHigh {
                        opacity = 1.0
                    } else {
                        let rawMediumOpacity = 1.0 - (Double(currentHeight - effectiveHigh) / Double(effectiveFade))
                        opacity = min(max(rawMediumOpacity, 0.0), 1.0)
                    }
                }
            }
        case .large:
            guard hasLargeDetent else {
                opacity = 0.0
                break
            }
            let gap = largeHeight - mediumHeight
            if gap <= 1 {
                opacity = sheetManager.selectedDetent == .large ? 1.0 : 0.0
            } else {
                let minStart = mediumHeight + gap * 0.5
                let effectiveStart = max(minStart, largeHeight - fadeRange)
                let effectiveFade = max(1, largeHeight - effectiveStart)
                let rawLargeOpacity = 1.0 - (Double(largeHeight - currentHeight) / Double(effectiveFade))
                opacity = min(max(rawLargeOpacity, 0.0), 1.0)
            }
        }

        return content.opacity(opacity)
    }
}
