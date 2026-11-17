//
//  GlassContainer.swift
//  CustomSheet
//
//  Created by Leonardo Rossi on 17/12/25.
//  Copyright (C) 2026 Leonardo Rossi
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import ObjectiveC

public struct SheetCornerRadii: Equatable {
    var tl: CGFloat
    var tr: CGFloat
    var bl: CGFloat
    var br: CGFloat
    
    public init(tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) {
        self.tl = tl
        self.tr = tr
        self.bl = bl
        self.br = br
    }
    
    public init (all: CGFloat) {
        self.tl = all
        self.tr = all
        self.bl = all
        self.br = all
    }
}

public enum GlassEffectStyle {
    case regular
    case clear
    
    @available(iOS 26, *)
    var glassStyle: UIGlassEffect.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

final class GlassContainerView: UIView {
    private let shadowView = UIView()
    private let glassView = UIVisualEffectView()
    
    var cornerRadii: SheetCornerRadii = .init(all: 0)
    var style: GlassEffectStyle = .regular { didSet { updateAppearance() } }
    var tint: UIColor? = nil { didSet { updateAppearance() } }
    var isEnabled = true { didSet { updateAppearance() } }
    var resetTrigger: Int = 0 { didSet { resetEffect() } }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setup() {
        if #unavailable(iOS 26) {
            shadowView.backgroundColor = .clear
            shadowView.layer.shadowColor = UIColor.black.cgColor
            shadowView.layer.shadowOffset = CGSize(width: 0, height: 0)
            shadowView.layer.shadowRadius = 2
            addSubview(shadowView)
        }
        
        addSubview(glassView)
        glassView.clipsToBounds = true
        
        if #available(iOS 26, *) {
            registerForTraitChanges([UITraitActiveAppearance.self, UITraitUserInterfaceStyle.self]) { (self: GlassContainerView, _) in
                UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.updateEffect()
                }
            }
        } else {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: GlassContainerView, _) in
                self.updateAppearance()
            }
        }
        updateAppearance()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        if #unavailable(iOS 26) { shadowView.frame = bounds }
        glassView.frame = bounds
        
        if #unavailable(iOS 26) {
            applyCornerMask()
            updateShadowPath()
        }
    }
    
    private func updateAppearance() {
        updateEffect()
        if #unavailable(iOS 26) { updateShadow() }
    }
    
    private func updateEffect() {
        if isEnabled {
            if #available(iOS 26, *) {
                let effect = UIGlassEffect(style: style.glassStyle)
                effect.isInteractive = true
                effect.tintColor = tint
                glassView.effect = effect
            } else {
                glassView.effect = nil
                glassView.backgroundColor = traitCollection.userInterfaceStyle == .dark ?
                    .secondarySystemBackground :
                    .systemBackground
            }
        } else {
            glassView.effect = nil
        }
    }
    
    private func updateShadow() {
        let shouldShowShadow = traitCollection.userInterfaceStyle != .dark
        UIView.animate(withDuration: 0.2) {
            self.shadowView.layer.shadowOpacity = shouldShowShadow ? 0.1 : 0.0
        }
    }
    
    private func resetEffect() {
        glassView.effect = nil
        DispatchQueue.main.async { self.updateEffect() }
    }
    
    var contentView: UIView { return glassView.contentView }

    func applyLiveCorners(_ radii: SheetCornerRadii) {
        let changed = abs(cornerRadii.tl - radii.tl) > 0.001
            || abs(cornerRadii.tr - radii.tr) > 0.001
            || abs(cornerRadii.bl - radii.bl) > 0.001
            || abs(cornerRadii.br - radii.br) > 0.001
        guard changed else { return }
        cornerRadii = radii
        if #available(iOS 26, *) {
            applyCorners(animated: false, duration: 0)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyCornerMask()
            updateShadowPath()
            CATransaction.commit()
        }
    }
    
    func applyCorners(animated: Bool, duration: TimeInterval, useSpring: Bool = false) {
        let block = {
            if #available(iOS 26, *) {
                let corners: UICornerConfiguration = .corners(
                    topLeftRadius: .fixed(self.cornerRadii.tl),
                    topRightRadius: .fixed(self.cornerRadii.tr),
                    bottomLeftRadius: .fixed(self.cornerRadii.bl),
                    bottomRightRadius: .fixed(self.cornerRadii.br)
                )
                if self.glassView.cornerConfiguration != corners {
                    self.glassView.cornerConfiguration = corners
                }
            } else {
                self.applyCornerMask()
                self.updateShadowPath()
            }
        }
        
        if animated {
            if useSpring {
                if #available(iOS 17.0, *) {
                    UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction], animations: block)
                } else {
                    UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.95, initialSpringVelocity: 0, options: [.allowUserInteraction], animations: block)
                }
            } else {
                UIView.animate(withDuration: duration, animations: block)
            }
        } else { block() }
    }
    
    private func applyCornerMask() {
        let maxRadius = max(cornerRadii.tl, cornerRadii.tr, cornerRadii.bl, cornerRadii.br)
        
        var maskedCorners: CACornerMask = []
        if cornerRadii.tl > 0 { maskedCorners.insert(.layerMinXMinYCorner) }
        if cornerRadii.tr > 0 { maskedCorners.insert(.layerMaxXMinYCorner) }
        if cornerRadii.bl > 0 { maskedCorners.insert(.layerMinXMaxYCorner) }
        if cornerRadii.br > 0 { maskedCorners.insert(.layerMaxXMaxYCorner) }
        
        glassView.layer.cornerRadius = maxRadius
        glassView.layer.maskedCorners = maskedCorners
    }
    
    private func updateShadowPath() {
        var rectCorners: UIRectCorner = []
        let masked = glassView.layer.maskedCorners
        if masked.contains(.layerMinXMinYCorner) { rectCorners.insert(.topLeft) }
        if masked.contains(.layerMaxXMinYCorner) { rectCorners.insert(.topRight) }
        if masked.contains(.layerMinXMaxYCorner) { rectCorners.insert(.bottomLeft) }
        if masked.contains(.layerMaxXMaxYCorner) { rectCorners.insert(.bottomRight) }
        
        shadowView.layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            byRoundingCorners: rectCorners,
            cornerRadii: CGSize(width: glassView.layer.cornerRadius, height: glassView.layer.cornerRadius)
        ).cgPath
    }
}

nonisolated(unsafe) private var verticalSafeAreaStripKey: UInt8 = 0

@MainActor
private final class VerticalSafeAreaStripConfig: NSObject {
    var stripTop: Bool
    var stripBottom: Bool
    var preserveKeyboard: Bool

    init(stripTop: Bool, stripBottom: Bool, preserveKeyboard: Bool) {
        self.stripTop = stripTop
        self.stripBottom = stripBottom
        self.preserveKeyboard = preserveKeyboard
    }
}

@MainActor
private final class SheetKeyboardTracker {
    static let shared = SheetKeyboardTracker()
    private(set) var screenFrame: CGRect = .zero

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let endFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated {
                self?.screenFrame = endFrame
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenFrame = .zero
            }
        }
    }

    func bottomOverlap(for view: UIView) -> CGFloat {
        guard !screenFrame.isEmpty,
              let window = view.window,
              let screen = window.windowScene?.screen else {
            return 0
        }
        let kbInWindow = window.convert(screenFrame, from: screen.coordinateSpace)
        let intersected = kbInWindow.intersection(window.bounds)
        guard !intersected.isNull, intersected.height > 0 else { return 0 }
        let viewInWindow = view.convert(view.bounds, to: window)
        return max(0, min(viewInWindow.maxY, window.bounds.maxY) - intersected.minY)
    }
}

@MainActor
enum SheetVerticalSafeAreaStripper {
    nonisolated(unsafe) private static var swizzledClasses: Set<ObjectIdentifier> = []

    static func attach(to view: UIView, stripTop: Bool, stripBottom: Bool, preserveKeyboard: Bool) {
        if let existing = objc_getAssociatedObject(view, &verticalSafeAreaStripKey) as? VerticalSafeAreaStripConfig {
            existing.stripTop = stripTop
            existing.stripBottom = stripBottom
            existing.preserveKeyboard = preserveKeyboard
            return
        }
        _ = SheetKeyboardTracker.shared
        objc_setAssociatedObject(
            view,
            &verticalSafeAreaStripKey,
            VerticalSafeAreaStripConfig(
                stripTop: stripTop,
                stripBottom: stripBottom,
                preserveKeyboard: preserveKeyboard
            ),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        swizzleIfNeeded(type(of: view))
    }

    static func attachNavigationDescendants(in rootController: UIViewController) {
        if let nav = rootController as? UINavigationController {
            attachToNavigationController(nav)
            return
        }
        for child in rootController.children {
            attachNavigationDescendants(in: child)
        }
    }

    static func attachToNavigationController(_ nav: UINavigationController) {
        if let navView = nav.viewIfLoaded {
            attach(to: navView, stripTop: false, stripBottom: true, preserveKeyboard: true)
            attachScrollViews(in: navView)
        }
        for vc in nav.viewControllers {
            if let vcView = vc.viewIfLoaded {
                attach(to: vcView, stripTop: false, stripBottom: true, preserveKeyboard: true)
            }
        }
    }

    private static func attachScrollViews(in root: UIView) {
        if root is UIScrollView {
            attach(to: root, stripTop: false, stripBottom: true, preserveKeyboard: true)
        }
        for subview in root.subviews {
            attachScrollViews(in: subview)
        }
    }

    private static func swizzleIfNeeded(_ viewClass: UIView.Type) {
        var ancestor: AnyClass? = viewClass
        while let current = ancestor {
            if swizzledClasses.contains(ObjectIdentifier(current)) {
                return
            }
            if current == UIView.self { break }
            ancestor = class_getSuperclass(current)
        }

        let sel = #selector(getter: UIView.safeAreaInsets)
        guard let method = class_getInstanceMethod(viewClass, sel) else { return }

        typealias SafeAreaIMP = @convention(c) @Sendable (UIView, Selector) -> UIEdgeInsets
        let originalImp = method_getImplementation(method)
        let originalGetter = unsafeBitCast(originalImp, to: SafeAreaIMP.self)

        let block: @convention(block) (UIView) -> UIEdgeInsets = { view in
            MainActor.assumeIsolated {
                var insets = originalGetter(view, sel)
                if let config = objc_getAssociatedObject(view, &verticalSafeAreaStripKey) as? VerticalSafeAreaStripConfig {
                    if config.stripTop {
                        insets.top = 0
                    }
                    if config.stripBottom {
                        if config.preserveKeyboard {
                            let kbOverlap = SheetKeyboardTracker.shared.bottomOverlap(for: view)
                            insets.bottom = kbOverlap > 0 ? min(insets.bottom, kbOverlap) : 0
                        } else {
                            insets.bottom = 0
                        }
                    }
                }
                return insets
            }
        }

        swizzledClasses.insert(ObjectIdentifier(viewClass))
        let newImp = imp_implementationWithBlock(block)
        if !class_addMethod(viewClass, sel, newImp, method_getTypeEncoding(method)) {
            method_setImplementation(method, newImp)
        }
    }
}

final class SheetHostingController<Content: View>: UIHostingController<Content> {}

final class GlassHostContainerController: UIViewController {
    weak var glassContainer: GlassContainerView?
    weak var hostedView: UIView?
    weak var hostingViewController: UIViewController?
    var horizontalExpansion: CGFloat = 0 {
        didSet {
            guard oldValue != horizontalExpansion else { return }
            layoutHostedView()
        }
    }
    var fixedContentHeight: CGFloat = 0 {
        didSet {
            guard abs(oldValue - fixedContentHeight) > 0.5 else { return }
            layoutHostedView()
        }
    }
    var onLiveHeightChange: ((CGFloat) -> Void)?
    var isApplyingSetup: Bool = false
    private(set) var lastReportedHeight: CGFloat = -1

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHostedView()
    }

    func layoutHostedView(forceGlassLayout: Bool = false) {
        guard let glassContainer, let hostedView else { return }
        let containerBounds = view.bounds
        if glassContainer.frame != containerBounds {
            glassContainer.frame = containerBounds
            if forceGlassLayout {
                glassContainer.layoutIfNeeded()
            }
        } else if forceGlassLayout {
            glassContainer.layoutIfNeeded()
        }
        let targetHeight = max(
            containerBounds.height,
            fixedContentHeight > 0 ? fixedContentHeight : containerBounds.height
        )
        let targetFrame = CGRect(
            x: -horizontalExpansion,
            y: 0,
            width: containerBounds.width + (horizontalExpansion * 2),
            height: targetHeight
        )
        if hostedView.frame != targetFrame {
            hostedView.frame = targetFrame
        }
        if let hostingViewController {
            SheetVerticalSafeAreaStripper.attachNavigationDescendants(in: hostingViewController)
        }
        if !isApplyingSetup,
           containerBounds.height > 0,
           let onLiveHeightChange,
           abs(containerBounds.height - lastReportedHeight) > 0.01 {
            lastReportedHeight = containerBounds.height
            onLiveHeightChange(containerBounds.height)
        }
    }
}

@MainActor
final class GlassContainerRef {
    weak var glass: GlassContainerView?

    func applyLiveCorners(_ radii: SheetCornerRadii) {
        glass?.applyLiveCorners(radii)
    }
}

public struct GlassContainer<Content: View>: UIViewControllerRepresentable {
    var radii: SheetCornerRadii
    var style: GlassEffectStyle = .regular
    var tint: Color? = nil
    var animationDuration: TimeInterval = 0.2
    var useSpring: Bool = false
    var isEnabled: Bool = true
    var isDragging: Bool = false
    var resetGlassEffect: Int = 0
    var fixedContentHeight: CGFloat = 0
    var horizontalContentExpansion: CGFloat = 0
    var glassRef: GlassContainerRef? = nil
    var onLiveHeightChange: ((CGFloat) -> Void)? = nil
    private let content: Content
    
    public init(
        radii: SheetCornerRadii,
        style: GlassEffectStyle = .regular,
        tint: Color? = nil,
        animationDuration: TimeInterval = 0.2,
        useSpring: Bool = false,
        isEnabled: Bool = true,
        isDragging: Bool = false,
        resetGlassEffect: Int = 0,
        fixedContentHeight: CGFloat = 0,
        horizontalContentExpansion: CGFloat = 0,
        onLiveHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            radii: radii,
            style: style,
            tint: tint,
            animationDuration: animationDuration,
            useSpring: useSpring,
            isEnabled: isEnabled,
            isDragging: isDragging,
            resetGlassEffect: resetGlassEffect,
            fixedContentHeight: fixedContentHeight,
            horizontalContentExpansion: horizontalContentExpansion,
            glassRef: nil,
            onLiveHeightChange: onLiveHeightChange,
            content: content
        )
    }

    init(
        radii: SheetCornerRadii,
        style: GlassEffectStyle = .regular,
        tint: Color? = nil,
        animationDuration: TimeInterval = 0.2,
        useSpring: Bool = false,
        isEnabled: Bool = true,
        isDragging: Bool = false,
        resetGlassEffect: Int = 0,
        fixedContentHeight: CGFloat = 0,
        horizontalContentExpansion: CGFloat = 0,
        glassRef: GlassContainerRef? = nil,
        onLiveHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.radii = radii
        self.style = style
        self.tint = tint
        self.animationDuration = animationDuration
        self.useSpring = useSpring
        self.isEnabled = isEnabled
        self.isDragging = isDragging
        self.resetGlassEffect = resetGlassEffect
        self.fixedContentHeight = fixedContentHeight
        self.horizontalContentExpansion = horizontalContentExpansion
        self.glassRef = glassRef
        self.onLiveHeightChange = onLiveHeightChange
        self.content = content()
    }
    
    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = GlassHostContainerController()
        
        let glassContainer = GlassContainerView()
        glassContainer.cornerRadii = radii
        glassContainer.style = style
        if let tint { glassContainer.tint = UIColor(tint) }
        glassContainer.isEnabled = isEnabled
        glassContainer.resetTrigger = resetGlassEffect
        glassContainer.applyCorners(animated: false, duration: 0)
        
        controller.view.addSubview(glassContainer)
        glassContainer.frame = controller.view.bounds
        glassContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        let hosting = SheetHostingController(rootView: content)
        hosting.view.backgroundColor = .clear
        hosting.view.insetsLayoutMarginsFromSafeArea = false
        hosting.safeAreaRegions = [.container]
        hosting.traitOverrides.userInterfaceLevel = .elevated
        SheetVerticalSafeAreaStripper.attach(
            to: hosting.view,
            stripTop: true,
            stripBottom: true,
            preserveKeyboard: false
        )
        
        glassContainer.contentView.addSubview(hosting.view)
        controller.isApplyingSetup = true
        controller.glassContainer = glassContainer
        controller.hostedView = hosting.view
        controller.hostingViewController = hosting
        controller.fixedContentHeight = fixedContentHeight
        controller.horizontalExpansion = horizontalContentExpansion
        controller.onLiveHeightChange = onLiveHeightChange
        controller.layoutHostedView(forceGlassLayout: true)
        controller.isApplyingSetup = false
        
        controller.addChild(hosting)
        hosting.didMove(toParent: controller)
        
        context.coordinator.glassContainer = glassContainer
        context.coordinator.hostingController = hosting
        glassRef?.glass = glassContainer
        
        return controller
    }
    
    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let shouldAnimate = (context.transaction.animation != nil)
        if let hostController = uiViewController as? GlassHostContainerController {
            hostController.isApplyingSetup = true
            hostController.onLiveHeightChange = onLiveHeightChange
            hostController.fixedContentHeight = fixedContentHeight
            hostController.horizontalExpansion = horizontalContentExpansion
            hostController.isApplyingSetup = false
        }
        if let glass = context.coordinator.glassContainer {
            glassRef?.glass = glass
            if glassRef == nil {
                let radiiChanged = glass.cornerRadii != radii
                if radiiChanged {
                    glass.cornerRadii = radii
                    glass.applyCorners(animated: shouldAnimate, duration: animationDuration, useSpring: useSpring)
                }
            }
            if glass.style != style { glass.style = style }
            
            let newTint = tint.map { UIColor($0) }
            if glass.tint != newTint { glass.tint = newTint }
            
            let enabledChanged = glass.isEnabled != isEnabled
            if enabledChanged {
                glass.isEnabled = isEnabled
            }
            
            if glass.resetTrigger != resetGlassEffect { glass.resetTrigger = resetGlassEffect }
            
            if !isDragging || enabledChanged {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    context.coordinator.hostingController?.rootView = content
                }
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public class Coordinator {
        weak var glassContainer: GlassContainerView?
        weak var hostingController: UIHostingController<Content>?
    }
}
