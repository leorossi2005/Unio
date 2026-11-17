//
//  SheetDragger.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 16/12/25.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import QuartzCore

private final class DisplayLinkProxy: NSObject {
    @objc func tick() {}
}

enum CustomSheetDraggingDirection {
    case up, down, none
}

final class SheetPanGestureRecognizer: UIPanGestureRecognizer {
    var onTouchBegan: ((UITouch) -> Void)?
    var onTouchEndedWithoutBegin: (() -> Void)?
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let touch = touches.first {
            onTouchBegan?(touch)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if state == .possible || state == .failed || state == .cancelled {
            onTouchEndedWithoutBegin?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if state == .possible || state == .failed || state == .cancelled {
            onTouchEndedWithoutBegin?()
        }
    }
}

struct SheetDragger: UIViewRepresentable {
    var direction: CustomSheetDraggingDirection = .none
    var isAtLargeDetent: Bool = false
    
    var onDrag: (CGFloat, CustomSheetDraggingDirection) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PassThroughView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class PassThroughView: UIView {
        weak var coordinator: Coordinator?
        
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            return nil
        }
        
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window = window {
                coordinator?.setupGesture(on: window, targetedTo: self)
            } else {
                coordinator?.removeGesture()
            }
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SheetDragger
        weak var targetView: UIView?
        weak var window: UIWindow?
        weak var trackedScrollView: UIScrollView?
        var savedShowsVerticalScrollIndicator: Bool = true
        var savedBounces: Bool = true
    
        private weak var lockedPanScrollView: UIScrollView?
        private var isForcingOffset: Bool = false
        
        var isDraggingSheet: Bool = false
        var canHandoffToSheet: Bool = false
        var startedAtLargeDetent: Bool = false
        var gesture: SheetPanGestureRecognizer?

        nonisolated(unsafe) private var displayLink: CADisplayLink?
        private let displayLinkProxy = DisplayLinkProxy()
        private var isSheetPanActive: Bool = false
        private var displayLinkStopToken: Int = 0
        
        init(parent: SheetDragger) {
            self.parent = parent
        }

        deinit {
            displayLink?.invalidate()
        }
        
        func setupGesture(on window: UIWindow, targetedTo view: UIView) {
            removeGesture()
            self.window = window
            self.targetView = view
            
            let gesture = SheetPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            gesture.delegate = self
            gesture.cancelsTouchesInView = false
            
            gesture.onTouchBegan = { [weak self] touch in
                guard let self else { return }
                self.captureInitialScrollState(for: touch)
                if self.canHandoffToSheet {
                    self.primeProMotionDisplayLink()
                }
            }
            gesture.onTouchEndedWithoutBegin = { [weak self] in
                guard let self else { return }
                if !self.isSheetPanActive {
                    self.stopProMotionDisplayLink(immediate: true)
                }
            }
            
            window.addGestureRecognizer(gesture)
            self.gesture = gesture
        }
        
        func removeGesture() {
            stopProMotionDisplayLink(immediate: true)
            stopLockingScrollView()
            if let gesture = gesture {
                window?.removeGestureRecognizer(gesture)
            }
        }

        private func createProMotionDisplayLinkIfNeeded() {
            displayLinkStopToken &+= 1
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: displayLinkProxy, selector: #selector(DisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func primeProMotionDisplayLink() {
            displayLinkStopToken &+= 1
            createProMotionDisplayLinkIfNeeded()
        }

        private func startProMotionDisplayLink() {
            displayLinkStopToken &+= 1
            if !isSheetPanActive {
                isSheetPanActive = true
            }
            createProMotionDisplayLinkIfNeeded()
        }

        private func stopProMotionDisplayLink(immediate: Bool = false) {
            let wasActive = isSheetPanActive
            isSheetPanActive = false
            displayLinkStopToken &+= 1
            if !immediate && wasActive && displayLink != nil {
                // Keep the high-refresh hint active through the release spring so ProMotion stays at 120Hz.
                let expectedToken = displayLinkStopToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    guard let self,
                          self.displayLinkStopToken == expectedToken,
                          !self.isSheetPanActive else { return }
                    self.displayLink?.invalidate()
                    self.displayLink = nil
                }
            } else {
                displayLink?.invalidate()
                displayLink = nil
            }
        }

        private func startLockingScrollView(_ scrollView: UIScrollView) {
            stopLockingScrollView()
            lockedPanScrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))
        }

        private func stopLockingScrollView() {
            if let sv = lockedPanScrollView {
                sv.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollViewPan(_:)))
                lockedPanScrollView = nil
            }
        }

        @objc private func handleScrollViewPan(_ gesture: UIPanGestureRecognizer) {
            guard isDraggingSheet,
                  !isForcingOffset,
                  let scrollView = lockedPanScrollView else { return }
            
            let topOffset = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y != topOffset {
                isForcingOffset = true
                scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: topOffset)
                gesture.setTranslation(.zero, in: scrollView)
                isForcingOffset = false
            }
        }
        
        private func captureInitialScrollState(for touch: UITouch) {
            guard let window = window, let targetView = targetView else { return }
            
            stopLockingScrollView()
            
            let locationInTarget = touch.location(in: targetView)
            guard targetView.bounds.contains(locationInTarget) else {
                trackedScrollView = nil
                canHandoffToSheet = false
                return
            }
            
            startedAtLargeDetent = parent.isAtLargeDetent
            
            let locationInWindow = touch.location(in: window)
            var viewToCheck = window.hitTest(locationInWindow, with: nil)
            var foundScrollView: UIScrollView? = nil
            
            while let view = viewToCheck {
                if let sv = view as? UIScrollView {
                    if !sv.isPagingEnabled && sv.isScrollEnabled {
                        foundScrollView = sv
                        break
                    }
                }
                viewToCheck = view.superview
                if view == window { break }
            }
            
            self.trackedScrollView = foundScrollView
            self.isDraggingSheet = false
            
            if let sv = foundScrollView {
                self.savedShowsVerticalScrollIndicator = sv.showsVerticalScrollIndicator
                self.savedBounces = sv.bounces
                
                if !startedAtLargeDetent {
                    self.canHandoffToSheet = true
                    self.isDraggingSheet = true
                    startLockingScrollView(sv)
                    return
                }
                
                let topOffset = -sv.adjustedContentInset.top
                let deltaFromTop = sv.contentOffset.y - topOffset
                
                let isNearOrBouncingAtTop = (deltaFromTop >= -30.0 && deltaFromTop <= 6.0)
                self.canHandoffToSheet = isNearOrBouncingAtTop
                if isNearOrBouncingAtTop {
                    startLockingScrollView(sv)
                }
            } else {
                self.canHandoffToSheet = true
            }
        }
        
        private func lockScrollViewAtTop(_ scrollView: UIScrollView, topOffset: CGFloat) {
            isForcingOffset = true
            if scrollView.bounces { scrollView.bounces = false }
            if scrollView.showsVerticalScrollIndicator { scrollView.showsVerticalScrollIndicator = false }
            if scrollView.contentOffset.y != topOffset {
                scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: topOffset)
            }
            scrollView.panGestureRecognizer.setTranslation(.zero, in: scrollView)
            isForcingOffset = false
        }
        
        private func unlockScrollView(_ scrollView: UIScrollView) {
            if scrollView.bounces != savedBounces { scrollView.bounces = savedBounces }
            if scrollView.showsVerticalScrollIndicator != savedShowsVerticalScrollIndicator {
                scrollView.showsVerticalScrollIndicator = savedShowsVerticalScrollIndicator
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let window = window else { return }
            var translation = gesture.translation(in: window)
            let velocity = gesture.velocity(in: window)
            
            if let scrollView = trackedScrollView {
                let topOffset = -scrollView.adjustedContentInset.top
                
                if !startedAtLargeDetent {
                    isDraggingSheet = true
                    lockScrollViewAtTop(scrollView, topOffset: topOffset)
                } else {
                    if gesture.state == .began {
                        isDraggingSheet = false
                    }
                    
                    if !isDraggingSheet {
                        if scrollView.contentOffset.y <= topOffset + 6.0 && translation.y > 0 {
                            isDraggingSheet = true
                            lockScrollViewAtTop(scrollView, topOffset: topOffset)
                            
                            gesture.setTranslation(.zero, in: window)
                            translation = .zero
                        } else {
                            gesture.setTranslation(.zero, in: window)
                            translation = .zero
                        }
                    } else {
                        if translation.y <= 0 {
                            isDraggingSheet = false
                            stopProMotionDisplayLink()
                            unlockScrollView(scrollView)
                            
                            parent.onDrag(0, parent.direction)
                            
                            gesture.setTranslation(.zero, in: window)
                            translation = .zero
                        } else {
                            lockScrollViewAtTop(scrollView, topOffset: topOffset)
                        }
                    }
                }
            }
            
            if gesture.state == .began {
                if trackedScrollView == nil || isDraggingSheet {
                    startProMotionDisplayLink()
                    if translation.y != 0 {
                        parent.onDrag(translation.y, parent.direction)
                    }
                }
            } else if gesture.state == .changed {
                if trackedScrollView == nil || isDraggingSheet {
                    startProMotionDisplayLink()
                    parent.onDrag(translation.y, parent.direction)
                }
            } else if gesture.state == .ended || gesture.state == .cancelled {
                stopProMotionDisplayLink()
                parent.direction = .none
                let wasDraggingSheet = (trackedScrollView == nil) || isDraggingSheet
                
                stopLockingScrollView()
                
                if let scrollView = trackedScrollView {
                    unlockScrollView(scrollView)
                    if wasDraggingSheet {
                        let topY = -scrollView.adjustedContentInset.top
                        isForcingOffset = true
                        scrollView.panGestureRecognizer.setTranslation(.zero, in: scrollView)
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topY), animated: false)
                        isForcingOffset = false
                        
                        DispatchQueue.main.async {
                            if scrollView.isDecelerating || scrollView.contentOffset.y != topY {
                                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: topY), animated: false)
                            }
                        }
                    }
                }
                
                trackedScrollView = nil
                isDraggingSheet = false
                canHandoffToSheet = false
                
                if wasDraggingSheet {
                    let decelerationRate = 0.994
                    let extra = (velocity.y / 1000.0) * decelerationRate / (1 - decelerationRate)
                    let predictedEndTranslation = translation.y + extra
                    
                    parent.onEnded(translation.y, predictedEndTranslation)
                } else {
                    parent.onEnded(0, 0)
                }
            }
        }
        
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = window,
                  let targetView = targetView else { return false }
            
            let location = pan.location(in: targetView)
            if !targetView.bounds.contains(location) {
                return false
            }
            
            let velocity = pan.velocity(in: window)
            if abs(velocity.x) > abs(velocity.y) {
                return false
            }
            
            if trackedScrollView != nil && !canHandoffToSheet {
                return false
            }
            
            if parent.direction == .none {
                let translation = pan.translation(in: window)
                if translation.y < 0 {
                    parent.direction = .up
                } else if translation.y > 0 {
                    parent.direction = .down
                }
            }
            
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if otherGestureRecognizer.view is UIControl {
                return true
            }
            
            if let scrollView = otherGestureRecognizer.view as? UIScrollView {
                if scrollView.isPagingEnabled { return false }
                return true
            }
            return false
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let otherClass = String(describing: type(of: otherGestureRecognizer))
            let viewClass = otherGestureRecognizer.view.map { String(describing: type(of: $0)) } ?? ""
            
            let isStageManagerDrag = otherClass.contains("WindowScene") || otherClass.contains("DragInteraction") || otherClass.contains("SystemGesture")
            let isNavBarGesture = viewClass.contains("NavigationBar")
            
            if isStageManagerDrag || isNavBarGesture {
                return true
            }
            
            return false
        }
    }
}
