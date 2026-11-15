import Foundation
import UIKit
import Photos
import UniformTypeIdentifiers
import Display
import TelegramCore
import AccountContext
import DeviceAccess
import LegacyMediaPickerUI
import PresentationDataUtils
import SGSimpleSettings
import SGStrings

/// A reference-counted hard link, retained only while a viewer/export is alive.
/// It lets an explicitly enabled local export finish after the source expires.
public final class BYLocalMediaSnapshot {
    public let message: EngineRawMessage
    private let file: EngineTempBox.File
    fileprivate let isImage: Bool
    fileprivate let isVideo: Bool
    fileprivate var url: URL { URL(fileURLWithPath: self.file.path) }

    public init?(context: AccountContext, message: EngineRawMessage, media: EngineRawMedia? = nil) {
        guard message.byAllowsLocalSaving else { return nil }
        var resource: TelegramMediaResource?
        var name = "Photo.jpg"
        var isImage = false
        var isVideo = false
        let mediaItems = media.map { [$0] } ?? message.effectiveMedia
        for media in mediaItems {
            if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
                resource = representation.resource
                isImage = true
                break
            } else if let file = media as? TelegramMediaFile {
                resource = file.resource
                isVideo = file.isVideo || file.mimeType.hasPrefix("video/")
                let ext = UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? (isVideo ? "mp4" : "bin")
                name = BYLocalSaving.fileName(file.fileName, fallback: "Media." + ext)
                break
            }
        }
        guard let resource, let path = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(resource.id)) else { return nil }
        let file = EngineTempBox.shared.file(path: path, fileName: name)
        guard FileManager.default.fileExists(atPath: file.path) else {
            EngineTempBox.shared.dispose(file)
            return nil
        }
        self.message = message
        self.file = file
        self.isImage = isImage
        self.isVideo = isVideo
    }

    deinit {
        EngineTempBox.shared.dispose(self.file)
    }
}

/// Explicit local export of one downloaded resource; never forwards to Telegram.
public func byExportMediaLocally(context: AccountContext, message: EngineRawMessage, media: EngineRawMedia? = nil, snapshot: BYLocalMediaSnapshot? = nil, toFiles: Bool, present: @escaping (ViewController) -> Void) {
    guard message.byAllowsLocalSaving else { return }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let lang = presentationData.strings.baseLanguageCode
    let showMessage: (String) -> Void = { text in
        DispatchQueue.main.async {
            present(textAlertController(context: context, title: nil, text: text, actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]))
        }
    }
    let retainedSnapshot = media == nil && snapshot?.message.id == message.id ? snapshot : nil
    guard let export = retainedSnapshot ?? BYLocalMediaSnapshot(context: context, message: message, media: media) else {
        showMessage(i18n("Settings.BYPlugin.DownloadFirst", lang))
        return
    }
    if toFiles || (!export.isImage && !export.isVideo) {
        let controller = legacyICloudFilePicker(theme: presentationData.theme, mode: .export, url: export.url, documentTypes: [], completion: { [export] _ in
            withExtendedLifetime(export) {}
        })
        present(controller)
    } else {
        DeviceAccess.authorizeAccess(to: .mediaLibrary(.save), presentationData: presentationData, present: { c, a in
            context.sharedContext.presentGlobalController(c, a)
        }, openSettings: context.sharedContext.applicationBindings.openSettings, { authorized in
            guard authorized else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: export.isImage ? .photo : .video, fileURL: export.url, options: nil)
            }, completionHandler: { [export] success, _ in
                let text = success ? (export.isImage ? presentationData.strings.Gallery_ImageSaved : presentationData.strings.Gallery_VideoSaved) : i18n("Settings.BYPlugin.SaveFailed", lang)
                showMessage(text)
            })
        })
    }
}
