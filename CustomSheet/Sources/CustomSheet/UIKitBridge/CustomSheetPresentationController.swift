//
//  CustomSheetPresentationController.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 12/11/2026.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import SwiftUI
import ObjectiveC

// MARK: - Passthrough Manager for UITransitionView

nonisolated(unsafe) private var pcAssociationKey: UInt8 = 0

final class CustomSheetPassthroughManager: @unchecked Sendable {
    static let shared = CustomSheetPassthroughManager()
    private var swizzledClasses = Set<ObjectIdentifier>()
    private let lock = NSLock()
    
    func swizzleIfNeeded(for view: UIView) {
        lock.lock()
        defer { lock.unlock() }
        
        let viewClass: AnyClass = type(of: view)
        let id = ObjectIdentifier(viewClass)
        guard !swizzledClasses.contains(id) else { return }
        swizzledClasses.insert(id)
        
        let selector = #selector(UIView.hitTest(_:with:))
        guard let method = class_getInstanceMethod(viewClass, selector) else { return }
        
        typealias HitTestIMP = @convention(c) @Sendable (UIView, Selector, CGPoint, UIEvent?) -> UIView?
        let originalImp = method_getImplementation(method)
        let originalHitTest = unsafeBitCast(originalImp, to: HitTestIMP.self)
        
        let block: @convention(block) (UIView, CGPoint, UIEvent?) -> UIView? = { transitionView, point, event -> UIView? in
            MainActor.assumeIsolated { () -> UIView? in
                guard let pc = objc_getAssociatedObject(transitionView, &pcAssociationKey) as? CustomSheetPresentationController else {
                    return originalHitTest(transitionView, selector, point, event)
                }
                
                // Se la sheet è in stato .large modale o in trascinamento attivo, gestisci normalmente
                if pc.isLargeActive || pc.manager?.isDragging == true {
                    return originalHitTest(transitionView, selector, point, event)
                }
                
                if let sheetFrame = pc.sheetFrameInContainer() {
                    if !sheetFrame.contains(point) {
                        return nil
                    }
                } else {
                    let sheetHeight = pc.manager.map { $0.value(for: $0.selectedDetent) }
                        ?? pc.manager?.selectedDetent.value(fold: pc.fold ?? .shared)
                        ?? CustomSheetDetent.small.value(fold: pc.fold ?? .shared)
                    let sheetTop = transitionView.bounds.height - sheetHeight - 40
                    if point.y < sheetTop { return nil }
                }

                let hit = originalHitTest(transitionView, selector, point, event)
                if hit === transitionView {
                    return nil
                }
                return hit
            }
        }
        
        let newImp = imp_implementationWithBlock(block)
        method_setImplementation(method, newImp)
    }
}

// MARK: - Custom UIPresentationController

class CustomSheetPresentationController: UIPresentationController {
    weak var manager: GlobalSheetManager?
    weak var fold: FoldStateStore?
    var isLargeActive: Bool = false
    
    private weak var cachedGlassView: GlassContainerView?
    private var legacyScaleProgress: CGFloat = 0
    private var lastAppliedLegacyProgress: CGFloat = -1
    private var isDismissing: Bool = false
    private var presenterScaleBackup: PresenterScaleBackup?

    private struct PresenterScaleBackup {
        let cornerRadius: CGFloat
        let masksToBounds: Bool
        let cornerCurve: CALayerCornerCurve
        let maskedCorners: CACornerMask
        let windowBackgroundColor: UIColor?
    }
    
    init(
        presentedViewController: UIViewController,
        presenting presentingViewController: UIViewController?,
        manager: GlobalSheetManager?,
        fold: FoldStateStore? = nil
    ) {
        self.manager = manager
        self.fold = fold
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
    }
    
    override var shouldPresentInFullscreen: Bool {
        return true
    }
    
    override var shouldRemovePresentersView: Bool {
        return false
    }
    
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        if fold?.hasHinge ?? FoldStateStore.shared.hasHinge {
            return CGRect(
                x: 8,
                y: 0,
                width: max(0, containerView.bounds.width - 16),
                height: containerView.bounds.height
            )
        }
        return containerView.bounds
    }
    
    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let containerView else { return }
        
        containerView.backgroundColor = .clear
        presentedView?.backgroundColor = .clear
        
        // Eredita e sincronizza i trait dal controller che presenta (RootViewController)
        syncTraitOverrides()
        
        setupManagerCallbacks()
        
        // Collega il presentation controller al containerView per il passthrough dei tocchi
        objc_setAssociatedObject(containerView, &pcAssociationKey, self, .OBJC_ASSOCIATION_ASSIGN)
        CustomSheetPassthroughManager.shared.swizzleIfNeeded(for: containerView)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
        
        updateContainerFrame()
    }
    
    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        isDismissing = true
        updateLegacyPresenterScale(progress: 0, animated: true)
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            isDismissing = false
            legacyScaleProgress = 0
            updateLegacyPresenterScale(progress: 0, animated: false)
            if let containerView {
                objc_setAssociatedObject(containerView, &pcAssociationKey, nil, .OBJC_ASSOCIATION_ASSIGN)
            }
            NotificationCenter.default.removeObserver(
                self,
                name: UIAccessibility.voiceOverStatusDidChangeNotification,
                object: nil
            )
        } else {
            isDismissing = false
            updateLegacyPresenterScale(progress: legacyScaleProgress, animated: true, force: true)
        }
    }
    
    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        fold?.syncWindowMetrics()
        syncTraitOverrides()
        syncVerticalBarLayout()
        presentedView?.frame = frameOfPresentedViewInContainerView
        updateContainerFrame()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        if legacyScaleProgress > 0 {
            presentingViewController.view.transform = .identity
        }
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.updateLayout()
            self.updateLegacyPresenterScale(progress: self.legacyScaleProgress, animated: false, force: true)
        }) { [weak self] _ in
            guard let self else { return }
            self.updateLayout()
            self.updateLegacyPresenterScale(progress: self.legacyScaleProgress, animated: false, force: true)
        }
    }
    
    func updateLayout() {
        fold?.syncWindowMetrics()
        updateContainerFrame()
        syncVerticalBarLayout()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
    
    private func syncTraitOverrides() {
        let tc = presentingViewController.traitCollection
        
        if presentedViewController.traitCollection.horizontalSizeClass != tc.horizontalSizeClass {
            presentedViewController.traitOverrides.horizontalSizeClass = tc.horizontalSizeClass
        }
        if presentedViewController.traitCollection.verticalSizeClass != tc.verticalSizeClass {
            presentedViewController.traitOverrides.verticalSizeClass = tc.verticalSizeClass
        }
        if presentedViewController.traitCollection.layoutDirection != tc.layoutDirection {
            presentedViewController.traitOverrides.layoutDirection = tc.layoutDirection
        }
        if presentedViewController.traitCollection.userInterfaceStyle != tc.userInterfaceStyle {
            presentedViewController.traitOverrides.userInterfaceStyle = tc.userInterfaceStyle
        }
    }
    
    private func setupManagerCallbacks() {
        manager?.onBackgroundToggle = { [weak self] _ in
            self?.updateContainerFrame()
        }

        manager?.onLegacyScaleProgress = { [weak self] progress, animated in
            guard let self, !self.isDismissing else { return }
            self.legacyScaleProgress = progress
            self.updateLegacyPresenterScale(progress: progress, animated: animated)
        }
        
        manager?.onLargeDetentToggle = { [weak self] isLarge in
            guard let self else { return }
            self.isLargeActive = isLarge
            self.updateNavigationSafeArea(isLarge: isLarge)
            self.updateContainerFrame()
            
            let keepFocus = self.manager?.keepAccessibilityFocusOnLargeExit ?? false
            self.manager?.keepAccessibilityFocusOnLargeExit = false
            
            if self.containerView?.accessibilityViewIsModal != isLarge {
                self.containerView?.accessibilityViewIsModal = isLarge
                if UIAccessibility.isVoiceOverRunning {
                    if isLarge || !keepFocus {
                        UIAccessibility.post(notification: .layoutChanged, argument: nil)
                    } else {
                        UIAccessibility.post(notification: .layoutChanged, argument: self.containerView)
                    }
                }
            }
        }
        
        manager?.onDragToggle = { [weak self] _ in
            self?.updateContainerFrame()
        }
    }
    
    func updateContainerFrame() {
        guard let containerView, let window = containerView.window ?? presentingViewController.view.window else { return }
        if containerView.frame != window.bounds {
            containerView.frame = window.bounds
        }
    }
    
    @objc private func voiceOverStatusChanged() {
        guard UIAccessibility.isVoiceOverRunning,
              isLargeActive,
              let container = containerView else { return }
        
        container.accessibilityViewIsModal = false
        presentedView?.setNeedsLayout()
        presentedView?.layoutIfNeeded()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak container] in
            guard let self, let container, self.isLargeActive else { return }
            container.accessibilityViewIsModal = true
            UIAccessibility.post(notification: .screenChanged, argument: container)
        }
    }
    
    func updateNavigationSafeArea(isLarge: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncVerticalBarLayout(isLarge: isLarge)
            if let nav = self.findNavigationController() {
                let isDuo = fold?.hasHinge ?? FoldStateStore.shared.hasHinge
                let isDuoClosed = fold?.isClosed ?? FoldStateStore.shared.isClosed
                let isSplitView = fold?.splitScreen.isSplit ?? FoldStateStore.shared.splitScreen.isSplit
                let targetInset: CGFloat = isLarge ? ((isDuoClosed || isSplitView) ? 0 : (UIDevice.isIpad ? 8 : 16)) : 0
                DuoNavigationBarExpander.setExpanded(isLarge && isDuo && !isDuoClosed && !isSplitView, for: nav.navigationBar)
                if nav.additionalSafeAreaInsets.top != targetInset {
                    UIView.animate(withDuration: 0.2) {
                        nav.additionalSafeAreaInsets.top = targetInset
                        nav.view.layoutIfNeeded()
                    }
                }
            }
        }
    }

    private func syncVerticalBarLayout(isLarge: Bool? = nil) {
        guard let nav = findNavigationController() else { return }
        SheetVerticalSafeAreaStripper.attachToNavigationController(nav)
        let isDuo = fold?.hasHinge ?? FoldStateStore.shared.hasHinge
        let isDuoClosed = fold?.isClosed ?? FoldStateStore.shared.isClosed
        let splitScreen = fold?.splitScreen ?? FoldStateStore.shared.splitScreen
        let activeLarge = isLarge ?? isLargeActive

        let contentOffsetX: CGFloat
        if isDuo && (isDuoClosed || splitScreen == .right) {
            contentOffsetX = 4
        } else if isDuo && splitScreen == .left {
            contentOffsetX = -4
        } else {
            contentOffsetX = 0
        }

        DuoVerticalBarLayoutAdjuster.update(for: nav, contentOffsetX: contentOffsetX)

        let targetContentTop: CGFloat = (isDuo && isDuoClosed && activeLarge) ? 14 : 0
        for vc in nav.viewControllers where vc.additionalSafeAreaInsets.top != targetContentTop {
            vc.additionalSafeAreaInsets.top = targetContentTop
        }
    }

    private func findNavigationController() -> UINavigationController? {
        func findNav(in vc: UIViewController) -> UINavigationController? {
            if let nav = vc as? UINavigationController { return nav }
            for child in vc.children {
                if let nav = findNav(in: child) { return nav }
            }
            return nil
        }

        func findNavInView(_ view: UIView) -> UINavigationController? {
            if let nav = view.next as? UINavigationController { return nav }
            for sub in view.subviews {
                if let nav = findNavInView(sub) { return nav }
            }
            return nil
        }

        return findNav(in: presentedViewController) ?? presentedView.flatMap { findNavInView($0) }
    }
    
    func sheetFrameInContainer() -> CGRect? {
        guard let containerView else { return nil }
        
        if cachedGlassView?.window == nil {
            cachedGlassView = Self.findGlassView(in: presentedViewController.view)
        }
        guard let glass = cachedGlassView, glass.window != nil else { return nil }
        return glass.convert(glass.bounds, to: containerView)
    }

    private static func findGlassView(in view: UIView) -> GlassContainerView? {
        if let glass = view as? GlassContainerView { return glass }
        for sub in view.subviews {
            if let found = findGlassView(in: sub) { return found }
        }
        return nil
    }

    private var shouldApplyLegacyPresenterScale: Bool {
        if #available(iOS 26, *) {
            return false
        }
        return !UIDevice.isIpad
            && legacyScaleProgress > 0
            && presentingViewController.traitCollection.horizontalSizeClass == .compact
    }

    private func updateLegacyPresenterScale(progress: CGFloat, animated: Bool, force: Bool = false) {
        if #available(iOS 26, *) {
            return
        }
        guard let presenterView = presentingViewController.view else { return }
        let clamped = min(max(progress, 0), 1)
        let shouldScale = !UIDevice.isIpad
            && clamped > 0
            && presentingViewController.traitCollection.horizontalSizeClass == .compact

        if shouldScale {
            if !force && !animated && abs(clamped - lastAppliedLegacyProgress) <= 0.0005 && presenterScaleBackup != nil {
                return
            }
            if presenterScaleBackup == nil {
                presenterScaleBackup = PresenterScaleBackup(
                    cornerRadius: presenterView.layer.cornerRadius,
                    masksToBounds: presenterView.layer.masksToBounds,
                    cornerCurve: presenterView.layer.cornerCurve,
                    maskedCorners: presenterView.layer.maskedCorners,
                    windowBackgroundColor: presenterView.window?.backgroundColor
                )
            }

            let targetScale: CGFloat = 0.92
            let height = presenterView.bounds.height
            guard height > 0 else { return }
            let rawTopSafe = presenterView.window?.safeAreaInsets.top ?? presenterView.safeAreaInsets.top
            let topTarget = rawTopSafe > 0 ? rawTopSafe : 20
            let targetScaledTopOffset = (1 - targetScale) * height * 0.5
            let targetTy = topTarget - targetScaledTopOffset

            let currentScale = 1.0 - (1.0 - targetScale) * clamped
            let currentTy = targetTy * clamped
            let targetTransform = CGAffineTransform(translationX: 0, y: currentTy).scaledBy(x: currentScale, y: currentScale)

            let startRadius: CGFloat = CGFloat.deviceCornerRadius > 0 ? CGFloat.deviceCornerRadius : 0
            let currentRadius = startRadius + ((10 - startRadius) * clamped)

            let apply = {
                presenterView.window?.backgroundColor = .black
                presenterView.layer.masksToBounds = true
                presenterView.layer.cornerCurve = .continuous
                presenterView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                presenterView.transform = targetTransform
                presenterView.layer.cornerRadius = currentRadius
            }
            lastAppliedLegacyProgress = clamped
            if animated {
                UIView.animate(springDuration: 0.5, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                apply()
                CATransaction.commit()
            }
        } else if let backup = presenterScaleBackup {
            lastAppliedLegacyProgress = 0
            let restoreRadius = CGFloat.deviceCornerRadius > 0 ? CGFloat.deviceCornerRadius : backup.cornerRadius
            let apply = {
                presenterView.transform = .identity
                presenterView.layer.cornerRadius = animated ? restoreRadius : backup.cornerRadius
            }
            let finish = { [weak self] in
                guard let self, !self.shouldApplyLegacyPresenterScale else { return }
                presenterView.layer.cornerRadius = backup.cornerRadius
                presenterView.layer.masksToBounds = backup.masksToBounds
                presenterView.layer.cornerCurve = backup.cornerCurve
                presenterView.layer.maskedCorners = backup.maskedCorners
                presenterView.window?.backgroundColor = backup.windowBackgroundColor
                self.presenterScaleBackup = nil
            }
            if animated {
                UIView.animate(springDuration: 0.5, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply) { _ in
                    finish()
                }
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                apply()
                finish()
                CATransaction.commit()
            }
        } else {
            lastAppliedLegacyProgress = 0
        }
    }
}

// MARK: - Host View Controller

final class CustomSheetHostViewController: UIViewController {
    var onWindowAvailable: (() -> Void)?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onWindowAvailable?()
    }
    
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if view.window != nil {
            onWindowAvailable?()
        }
    }
    
    func targetPresenter() -> UIViewController? {
        guard let window = view.window else { return nil }
        guard let root = window.rootViewController else { return self }
        var top = root
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

final class CustomSheetRootHostingController<Content: View>: UIHostingController<Content> {
    var allowDismiss: Bool = false
    
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil || allowDismiss {
            super.dismiss(animated: flag, completion: completion)
        } else {
            completion?()
        }
    }
}

// MARK: - UIViewControllerRepresentable Bridge

struct CustomSheetPresentationBridge<SheetContent: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var manager: GlobalSheetManager?
    var detents: [CustomSheetDetent]
    let sheetContent: () -> SheetContent
    
    init(
        isPresented: Binding<Bool>,
        manager: GlobalSheetManager?,
        detents: [CustomSheetDetent],
        @ViewBuilder sheetContent: @escaping () -> SheetContent
    ) {
        self._isPresented = isPresented
        self.manager = manager
        self.detents = detents
        self.sheetContent = sheetContent
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIViewController(context: Context) -> CustomSheetHostViewController {
        let vc = CustomSheetHostViewController()
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CustomSheetHostViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.manager = manager
        if let window = uiViewController.view.window {
            coordinator.fold.window = window
            coordinator.fold.syncWindowMetrics()
        }
        
        let env = context.environment
        let makeRootView: () -> AnyView = {
            AnyView(
                CustomSheet(
                    isPresented: $isPresented,
                    detents: detents,
                    manager: manager,
                    fold: coordinator.fold,
                    content: sheetContent
                )
                .environment(\.self, env)
            )
        }
        
        let performPresentation: () -> Void = { [weak uiViewController, weak coordinator] in
            guard let host = uiViewController, let coordinator else { return }
            guard let window = host.view.window else { return }
            coordinator.fold.window = window
            coordinator.fold.syncWindowMetrics()
            guard let presenter = host.targetPresenter() else { return }
            
            if isPresented {
                if let hc = coordinator.hostingController, hc.presentingViewController != nil || hc.isBeingPresented {
                    hc.rootView = makeRootView()
                    coordinator.presentationController?.updateLayout()
                } else {
                    coordinator.hostingController = nil
                    if presenter.presentedViewController == nil {
                        let hc = CustomSheetRootHostingController(rootView: makeRootView())
                        hc.view.backgroundColor = .clear
                        hc.view.clipsToBounds = false
                        hc.safeAreaRegions = []
                        hc.modalPresentationStyle = .custom
                        hc.transitioningDelegate = coordinator
                        
                        coordinator.hostingController = hc
                        presenter.present(hc, animated: false) {
                            coordinator.presentationController?.updateLayout()
                        }
                    }
                }
            } else {
                if let hc = coordinator.hostingController {
                    coordinator.hostingController = nil
                    coordinator.presentationController = nil
                    if hc.presentingViewController != nil {
                        hc.allowDismiss = true
                        hc.dismiss(animated: false)
                    }
                }
            }
        }
        
        uiViewController.onWindowAvailable = performPresentation
        if uiViewController.view.window != nil {
            performPresentation()
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: CustomSheetHostViewController, coordinator: Coordinator) {
        if let hc = coordinator.hostingController {
            coordinator.hostingController = nil
            coordinator.presentationController = nil
            if hc.presentingViewController != nil {
                hc.allowDismiss = true
                hc.dismiss(animated: false)
            }
        }
    }
    
    class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        weak var presentationController: CustomSheetPresentationController?
        var hostingController: CustomSheetRootHostingController<AnyView>?
        var manager: GlobalSheetManager?
        let fold = FoldStateStore()
        
        func presentationController(
            forPresented presented: UIViewController,
            presenting: UIViewController?,
            source: UIViewController
        ) -> UIPresentationController? {
            let pc = CustomSheetPresentationController(
                presentedViewController: presented,
                presenting: presenting,
                manager: manager,
                fold: fold
            )
            self.presentationController = pc
            return pc
        }
    }
}

@MainActor
enum DuoNavigationBarExpander {
    nonisolated(unsafe) private static var expandedKey: UInt8 = 0
    nonisolated(unsafe) private static var isSwizzled = false
    private static let horizontalExpansion: CGFloat = 4

    static func setExpanded(_ expanded: Bool, for navBar: UINavigationBar) {
        swizzleIfNeeded()
        let wasExpanded = isExpanded(navBar)
        objc_setAssociatedObject(
            navBar,
            &expandedKey,
            expanded ? NSNumber(value: true) : nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        if expanded {
            applyExpansionIfNeeded(to: navBar)
        } else if wasExpanded,
                  let sv = navBar.superview,
                  abs(navBar.frame.origin.x + horizontalExpansion) < 0.5,
                  abs(navBar.frame.width - (sv.bounds.width + horizontalExpansion * 2)) < 1.0 {
            var restored = navBar.frame
            restored.origin.x = 0
            restored.size.width = sv.bounds.width
            navBar.frame = restored
        }

        if wasExpanded != expanded || expanded {
            navBar.setNeedsLayout()
            navBar.layoutIfNeeded()
        }
    }

    private static func isExpanded(_ navBar: UINavigationBar) -> Bool {
        (objc_getAssociatedObject(navBar, &expandedKey) as? NSNumber)?.boolValue ?? false
    }

    private static func applyExpansionIfNeeded(to navBar: UINavigationBar) {
        guard isExpanded(navBar), let sv = navBar.superview else { return }
        let svWidth = sv.bounds.width
        guard svWidth > 0,
              abs(navBar.frame.size.width - svWidth) < 1.0,
              abs(navBar.frame.origin.x) < 0.5 || abs(navBar.frame.origin.x + horizontalExpansion) < 0.5 else {
            return
        }
        var adjusted = navBar.frame
        adjusted.origin.x = -horizontalExpansion
        adjusted.size.width = svWidth + horizontalExpansion * 2
        navBar.frame = adjusted
    }

    private static func swizzleIfNeeded() {
        guard !isSwizzled else { return }
        isSwizzled = true

        let targetClass: AnyClass = UINavigationBar.self

        let setFrameSel = #selector(setter: UIView.frame)
        if let method = class_getInstanceMethod(targetClass, setFrameSel) {
            typealias SetFrameIMP = @convention(c) @Sendable (UINavigationBar, Selector, CGRect) -> Void
            let originalImp = method_getImplementation(method)
            let originalSetFrame = unsafeBitCast(originalImp, to: SetFrameIMP.self)

            let block: @convention(block) (UINavigationBar, CGRect) -> Void = { navBar, rect in
                MainActor.assumeIsolated {
                    var adjusted = rect
                    if isExpanded(navBar), let sv = navBar.superview {
                        let svWidth = sv.bounds.width
                        if svWidth > 0,
                           abs(rect.size.width - svWidth) < 1.0,
                           abs(rect.origin.x) < 0.5 || abs(rect.origin.x + horizontalExpansion) < 0.5 {
                            adjusted.origin.x = -horizontalExpansion
                            adjusted.size.width = svWidth + horizontalExpansion * 2
                        }
                    }
                    originalSetFrame(navBar, setFrameSel, adjusted)
                }
            }
            let newImp = imp_implementationWithBlock(block)
            if !class_addMethod(targetClass, setFrameSel, newImp, method_getTypeEncoding(method)) {
                method_setImplementation(method, newImp)
            }
        }

        let layoutSel = #selector(UIView.layoutSubviews)
        if let method = class_getInstanceMethod(targetClass, layoutSel) {
            typealias LayoutIMP = @convention(c) @Sendable (UINavigationBar, Selector) -> Void
            let originalImp = method_getImplementation(method)
            let originalLayout = unsafeBitCast(originalImp, to: LayoutIMP.self)

            let block: @convention(block) (UINavigationBar) -> Void = { navBar in
                MainActor.assumeIsolated {
                    if isExpanded(navBar), let sv = navBar.superview {
                        let svWidth = sv.bounds.width
                        if svWidth > 0,
                           abs(navBar.frame.size.width - svWidth) < 1.0,
                           abs(navBar.frame.origin.x) < 0.5 || abs(navBar.frame.origin.x + horizontalExpansion) < 0.5 {
                            var b = navBar.bounds
                            b.size.width = svWidth + horizontalExpansion * 2
                            navBar.bounds = b
                            navBar.center = CGPoint(x: svWidth / 2.0, y: navBar.center.y)
                        }
                    }
                    originalLayout(navBar, layoutSel)
                }
            }
            let newImp = imp_implementationWithBlock(block)
            if !class_addMethod(targetClass, layoutSel, newImp, method_getTypeEncoding(method)) {
                method_setImplementation(method, newImp)
            }
        }
    }
}

@MainActor
private final class VerticalBarLayoutState: NSObject {
    weak var navigationController: UINavigationController?
    var contentOffsetX: CGFloat = 0
}

@MainActor
enum DuoVerticalBarLayoutAdjuster {
    nonisolated(unsafe) private static var stateKey: UInt8 = 0
    nonisolated(unsafe) private static var swizzledClasses: Set<ObjectIdentifier> = []

    static func update(for nav: UINavigationController, contentOffsetX: CGFloat) {
        guard let navView = nav.view else { return }
        swizzleIfNeeded(viewClass: type(of: navView))

        let state = (objc_getAssociatedObject(navView, &stateKey) as? VerticalBarLayoutState) ?? {
            let s = VerticalBarLayoutState()
            objc_setAssociatedObject(navView, &stateKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return s
        }()

        let changed = state.contentOffsetX != contentOffsetX
        state.navigationController = nav
        state.contentOffsetX = contentOffsetX

        if changed {
            navView.setNeedsLayout()
            navView.layoutIfNeeded()
        } else {
            applyTransforms(on: navView, state: state)
        }
    }

    private static func swizzleIfNeeded(viewClass: UIView.Type) {
        let classID = ObjectIdentifier(viewClass)
        guard !swizzledClasses.contains(classID) else { return }
        swizzledClasses.insert(classID)

        let layoutSel = #selector(UIView.layoutSubviews)
        guard let method = class_getInstanceMethod(viewClass, layoutSel) else { return }
        typealias LayoutIMP = @convention(c) @Sendable (UIView, Selector) -> Void
        let originalImp = method_getImplementation(method)
        let originalLayout = unsafeBitCast(originalImp, to: LayoutIMP.self)

        let block: @convention(block) (UIView) -> Void = { navView in
            MainActor.assumeIsolated {
                let state = objc_getAssociatedObject(navView, &stateKey) as? VerticalBarLayoutState
                if state != nil {
                    resetTransforms(on: navView)
                }
                originalLayout(navView, layoutSel)
                if let state {
                    if let nav = state.navigationController {
                        SheetVerticalSafeAreaStripper.attachToNavigationController(nav)
                    }
                    applyTransforms(on: navView, state: state)
                }
            }
        }
        let newImp = imp_implementationWithBlock(block)
        if !class_addMethod(viewClass, layoutSel, newImp, method_getTypeEncoding(method)) {
            method_setImplementation(method, newImp)
        }
    }

    private static func resetTransforms(on navView: UIView) {
        for sub in navView.subviews where sub.transform != .identity {
            sub.transform = .identity
        }
    }

    private static func applyTransforms(on navView: UIView, state: VerticalBarLayoutState) {
        guard let nav = state.navigationController else { return }
        let vcViews = nav.viewControllers.compactMap { $0.view }
        let contentContainer = navView.subviews.first { sub in
            sub !== nav.navigationBar && vcViews.contains { $0.isDescendant(of: sub) }
        }

        // Keep content aligned with GlassContainer's symmetric +/-4pt expansion by shifting toward the vertical bar side.
        if let contentContainer {
            let xOffset = state.contentOffsetX
            let targetTransform = xOffset != 0 ? CGAffineTransform(translationX: xOffset, y: 0) : .identity
            if contentContainer.transform != targetTransform {
                contentContainer.transform = targetTransform
            }
        }
    }
}
