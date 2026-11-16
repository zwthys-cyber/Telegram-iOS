import Foundation
import UIKit
import QuickLook
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import SGStrings

public func byMessageHistoryMediaController(context: AccountContext, recordKey: String, localId: String? = nil) -> ViewController {
    return BYHistoryMediaPreviewController(context: context, recordKey: recordKey, localId: localId)
}

private final class BYHistoryMediaPreviewController: ViewController, QLPreviewControllerDataSource {
    private let preview = QLPreviewController()
    private let placeholder = UILabel()
    private let disposable = MetaDisposable()
    private var file: BYHistoryPreviewFile?
    private var loaded = false
    private let missingText: String
    private var contentFrame = CGRect.zero

    init(context: AccountContext, recordKey: String, localId: String?) {
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let lang = data.strings.baseLanguageCode
        self.missingText = i18n("Settings.BYPlugin.History.MediaUnavailable", lang)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: data.theme.rootController.navigationBar, strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = i18n("Settings.BYPlugin.History.OpenAttachment", lang)
        self.statusBar.statusBarStyle = data.theme.overallDarkAppearance ? .White : .Black
        self.preview.dataSource = self
        self.overrideUserInterfaceStyle = data.theme.overallDarkAppearance ? .dark : .light
        self.placeholder.text = i18n("Settings.BYPlugin.History.LoadingAttachment", lang)
        self.placeholder.textColor = data.theme.list.itemPrimaryTextColor
        self.placeholder.font = UIFont.preferredFont(forTextStyle: .body)
        self.placeholder.adjustsFontForContentSizeCategory = true
        self.placeholder.numberOfLines = 0
        self.placeholder.textAlignment = .center
        self.disposable.set((context.engine.messages.byMessageHistoryFile(recordKey: recordKey, localId: localId)
        |> deliverOnMainQueue).start(next: { [weak self] file in
            guard let self else { return }
            self.file = file
            self.loaded = true
            if self.isViewLoaded { self.updateContent() }
        }))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.disposable.dispose() }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.view.addSubview(self.placeholder)
        self.updateContent()
    }

    private func updateContent() {
        if let file = self.file {
            self.title = file.url.lastPathComponent
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(self.share))
            self.placeholder.isHidden = true
            if self.preview.parent == nil {
                self.addChild(self.preview)
                self.view.addSubview(self.preview.view)
                self.preview.didMove(toParent: self)
            }
            self.preview.view.frame = self.contentFrame
            self.preview.reloadData()
        } else if self.loaded {
            self.placeholder.text = self.missingText
        }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        let bottom = max(layout.intrinsicInsets.bottom, layout.safeInsets.bottom)
        self.contentFrame = CGRect(x: layout.safeInsets.left, y: top,
            width: max(0, layout.size.width - layout.safeInsets.left - layout.safeInsets.right),
            height: max(0, layout.size.height - top - bottom))
        transition.updateFrame(view: self.placeholder, frame: self.contentFrame.insetBy(dx: 20, dy: 20))
        if self.preview.parent != nil { transition.updateFrame(view: self.preview.view, frame: self.contentFrame) }
    }

    @objc private func share() {
        guard let file = self.file else { return }
        let activity = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        activity.completionWithItemsHandler = { [file] _, _, _, _ in withExtendedLifetime(file) {} }
        if let popover = activity.popoverPresentationController {
            // Display's navigation bar is custom; its UIBarButtonItem has no UIKit bar view.
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: max(0, self.view.bounds.width - 44), y: max(0, self.contentFrame.minY - 1), width: 1, height: 1)
        }
        self.present(activity, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { self.file == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return self.file!.url as NSURL
    }
}
