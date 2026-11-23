//
//  CalendarSheetRouter.swift
//  Unio
//
//  Created by Leonardo Rossi on 16/06/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UnioCore
import CustomSheet

@MainActor
@Observable
class CalendarSheetRouter {
    var manager: GlobalSheetManager
    
    var selectedItem: CalendarItem? = nil
    var selectedRoom: Room? = nil
    var openSettings: Bool = false
    var openWhatsNew: Bool = false
    var openAddToCalendar: Bool = false
    var openAddPersonalEvent: Bool = false
    var openAppNotices: [AppNotice]? = nil
    var editingPersonalEvent: PersonalEvent? = nil
    var tempSettings: TempSettingsState = .init()
    
    var detents: [CustomSheetDetent] = [.small, .medium]
    
    init(selectedDetent: CustomSheetDetent? = nil) {
        if let detent = selectedDetent {
            manager = .init(initialDetent: detent)
        } else {
            manager = .init()
        }
    }
    
    // MARK: - Azioni di navigazione
    private func clearRoutes() {
        selectedItem = nil
        selectedRoom = nil
        openSettings = false
        openWhatsNew = false
        openAppNotices = nil
        openAddToCalendar = false
        openAddPersonalEvent = false
        editingPersonalEvent = nil
    }
    
    func routeToSettings() {
        clearRoutes()
        openSettings = true
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    func routeToWhatsNew() {
        clearRoutes()
        openWhatsNew = true
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    func routeToAppNotices(_ notices: [AppNotice]) {
        clearRoutes()
        openAppNotices = notices
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    func routeToItem(_ item: CalendarItem, addToCalendar: Bool = false) {
        clearRoutes()
        selectedItem = item
        openAddToCalendar = addToCalendar
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    func routeToRoom(_ room: Room) {
        clearRoutes()
        selectedRoom = room
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    func routeToAddPersonalEvent(editing event: PersonalEvent? = nil) {
        let preservedItem = event != nil ? selectedItem : nil
        clearRoutes()
        selectedItem = preservedItem
        editingPersonalEvent = event
        openAddPersonalEvent = true
        detents = [.small, .medium, .large]
        manager.setDetent(.large)
    }
    
    // MARK: - Reset automatico
    func resetToCalendar() {
        clearRoutes()
        detents = [.small, .medium]
    }
}
