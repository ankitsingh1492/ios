//
//  NCOperationQueue.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 03/06/2020.
//  Copyright © 2020 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//


import Foundation
import Queuer
import NCCommunication

@objc class NCOperationQueue: NSObject {
    @objc public static let shared: NCOperationQueue = {
        let instance = NCOperationQueue()
        return instance
    }()
    
    private var downloadQueue = Queuer(name: "downloadQueue", maxConcurrentOperationCount: 5, qualityOfService: .default)
    private let synchronizationQueue = Queuer(name: "synchronizationQueue", maxConcurrentOperationCount: 1, qualityOfService: .default)
    private let downloadThumbnailQueue = Queuer(name: "downloadThumbnailQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)
    private let readFileForMediaQueue = Queuer(name: "readFileForMediaQueue", maxConcurrentOperationCount: 10, qualityOfService: .default)

    private var timerReadFileForMediaQueue: Timer?

    @objc func cancelAllQueue() {
        downloadCancelAll()
        synchronizationCancelAll()
        downloadThumbnailCancelAll()
        readFileForMediaCancelAll()
    }
    
    // Download file
    
    @objc func download(metadata: tableMetadata, selector: String, setFavorite: Bool) {
        downloadQueue.addOperation(NCOperationDownload.init(metadata: metadata, selector: selector, setFavorite: setFavorite))
    }
    @objc func downloadCancelAll() {
        downloadQueue.cancelAll()
    }
    @objc func downloadCount() -> Int {
        return downloadQueue.operationCount
    }
    
    // Synchronization
    
    @objc func synchronizationMetadata(_ metadata: tableMetadata, selector: String) {
        synchronizationQueue.addOperation(NCOperationSynchronization.init(metadata: metadata, selector: selector))
    }
    @objc func synchronizationCancelAll() {
        synchronizationQueue.cancelAll()
    }
    
    // Download Thumbnail
    
    @objc func downloadThumbnail(metadata: tableMetadata, activeUrl: String, view: Any, indexPath: IndexPath) {
        if metadata.hasPreview && (!CCUtility.fileProviderStoragePreviewIconExists(metadata.ocId, etag: metadata.etag)) {
            for operation in  downloadThumbnailQueue.operations {
                if (operation as! NCOperationDownloadThumbnail).metadata.ocId == metadata.ocId { return }
            }
            downloadThumbnailQueue.addOperation(NCOperationDownloadThumbnail.init(metadata: metadata, activeUrl: activeUrl, view: view, indexPath: indexPath))
        }
    }
    
    func cancelDownloadThumbnail(metadata: tableMetadata) {
        for operation in  downloadThumbnailQueue.operations {
            if (operation as! NCOperationDownloadThumbnail).metadata.ocId == metadata.ocId {
                (operation as! NCOperationDownloadThumbnail).cancel()
            }
        }
    }
    
    @objc func downloadThumbnailCancelAll() {
        downloadThumbnailQueue.cancelAll()
    }
    
    // Get file information
    
    @objc func readFileForMedia(metadata: tableMetadata) {
        for operation in readFileForMediaQueue.operations {
            if (operation as! NCOperationReadFileForMediaQueue).metadata.ocId == metadata.ocId { return }
        }
        readFileForMediaQueue.addOperation(NCOperationReadFileForMediaQueue.init(metadata: metadata))
    }
    
    func cancelReadFileForMedia(metadata: tableMetadata) {
        for operation in  readFileForMediaQueue.operations {
            if (operation as! NCOperationReadFileForMediaQueue).metadata.ocId == metadata.ocId {
                (operation as! NCOperationReadFileForMediaQueue).cancel()
            }
        }
    }
    
    @objc func readFileForMediaCancelAll() {
        readFileForMediaQueue.cancelAll()
    }
    
    @objc func notificationReloadDataSourceMedia() {
        NotificationCenter.default.postOnMainThread(name: k_notificationCenter_reloadMediaDataSource)
    }
    
    func reloadDataSourceMedia() {
        if !(timerReadFileForMediaQueue?.isValid ?? false) {
            timerReadFileForMediaQueue = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(notificationReloadDataSourceMedia), userInfo: nil, repeats: false)
        }
    }
}

//MARK: -

class NCOperationDownload: ConcurrentOperation {
   
    private var metadata: tableMetadata
    private var selector: String
    private var setFavorite: Bool
    
    init(metadata: tableMetadata, selector: String, setFavorite: Bool) {
        self.metadata = metadata
        self.selector = selector
        self.setFavorite = setFavorite
    }
    
    override func start() {
        if isCancelled {
            self.finish()
        } else {
            NCNetworking.shared.download(metadata: metadata, selector: self.selector, setFavorite: self.setFavorite) { (_) in
                self.finish()
            }
        }
    }
}

//MARK: -

class NCOperationSynchronization: ConcurrentOperation {
   
    private var metadata: tableMetadata
    private var selector: String
    
    init(metadata: tableMetadata, selector: String) {
        self.metadata = metadata
        self.selector = selector
    }
    
    override func start() {
        if isCancelled {
            self.finish()
        } else {
            var depth: String = ""
            var serverUrlFileName: String = ""
            var predicate = NSPredicate()
            var download = false
            var useMetadataFolder = false
            if metadata.directory {
                depth = "infinity"
                useMetadataFolder = true
                serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName
                predicate = NSPredicate(format: "account == %@ AND serverUrl BEGINSWITH %@ AND status == %d", metadata.account, serverUrlFileName, k_metadataStatusNormal)
            } else {
                depth = "0"
                useMetadataFolder = false
                serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName
                predicate = NSPredicate(format: "account == %@ AND serverUrl == %@ AND fileName == %@ AND status == %d", metadata.account, metadata.serverUrl, metadata.fileName, k_metadataStatusNormal)
            }
            if selector == selectorDownloadSynchronize {
                download = true
            }
            
            NCCommunication.shared.readFileOrFolder(serverUrlFileName: serverUrlFileName, depth: depth, showHiddenFiles: CCUtility.getShowHiddenFiles()) { (account, files, responseData, errorCode, errorDescription) in
                if errorCode == 0 {
                    NCManageDatabase.sharedInstance.convertNCCommunicationFilesToMetadatas(files, useMetadataFolder: useMetadataFolder, account: account) { (metadataFolder, metadatasFolder, metadatas) in
                        if metadatas.count > 0 {
                            let metadatasResult = NCManageDatabase.sharedInstance.getMetadatas(predicate: predicate)
                            let metadatasChanged = NCManageDatabase.sharedInstance.updateMetadatas(metadatas, metadatasResult: metadatasResult, withVerifyLocal: download)
                            if download {
                                for metadata in metadatasChanged {
                                    if metadata.directory == false {
                                        NCNetworking.shared.download(metadata: metadata, selector: selectorDownloadSynchronize) { (_) in }
                                    }
                                }
                            }
                        }
                    }
                } else if errorCode == 404 && self.metadata.directory {
                    NCManageDatabase.sharedInstance.deleteDirectoryAndSubDirectory(serverUrl: self.metadata.serverUrl, account: self.metadata.account)
                }
                self.finish()
            }
        }
    }
}

//MARK: -

class NCOperationDownloadThumbnail: ConcurrentOperation {
   
    var metadata: tableMetadata
    var activeUrl: String
    var view: Any
    var indexPath: IndexPath
    
    init(metadata: tableMetadata, activeUrl: String, view: Any, indexPath: IndexPath) {
        self.metadata = metadata
        self.activeUrl = activeUrl
        self.view = view
        self.indexPath = indexPath
    }
    
    override func start() {

        if isCancelled {
            self.finish()
        } else {
            let fileNamePath = CCUtility.returnFileNamePath(fromFileName: metadata.fileName, serverUrl: metadata.serverUrl, activeUrl: activeUrl)!
            let fileNamePreviewLocalPath = CCUtility.getDirectoryProviderStoragePreviewOcId(metadata.ocId, etag: metadata.etag)!
            let fileNameIconLocalPath = CCUtility.getDirectoryProviderStorageIconOcId(metadata.ocId, etag: metadata.etag)!

            NCCommunication.shared.downloadPreview(fileNamePathOrFileId: fileNamePath, fileNamePreviewLocalPath: fileNamePreviewLocalPath , widthPreview: Int(k_sizePreview), heightPreview: Int(k_sizePreview), fileNameIconLocalPath: fileNameIconLocalPath, sizeIcon: Int(k_sizeIcon)) { (account, imagePreview, imageIcon,  errorCode, errorDescription) in
                
                var cell: NCImageCellProtocol?
                if self.view is UICollectionView && NCMainCommon.sharedInstance.isValidIndexPath(self.indexPath, view: self.view) {
                    cell = (self.view as! UICollectionView).cellForItem(at: self.indexPath) as? NCImageCellProtocol
                } else if self.view is UITableView && NCMainCommon.sharedInstance.isValidIndexPath(self.indexPath, view: self.view) {
                    cell = (self.view as! UITableView).cellForRow(at: self.indexPath) as? NCImageCellProtocol
                }

                if (cell != nil) {
                    var previewImage: UIImage!
                    if errorCode == 0 && imageIcon != nil {
                        previewImage = imageIcon
                    } else {
                        if self.metadata.iconName.count > 0 {
                            previewImage = UIImage(named: self.metadata.iconName)
                        } else {
                            previewImage = UIImage(named: "file")
                        }
                    }
                    cell!.filePreviewImageView.backgroundColor = nil
                    UIView.transition(with: cell!.filePreviewImageView,
                        duration: 0.75,
                        options: .transitionCrossDissolve,
                        animations: { cell!.filePreviewImageView.image = previewImage! },
                        completion: nil)
                }
                self.finish()
            }
        }
    }
}

//MARK: -

class NCOperationReadFileForMediaQueue: ConcurrentOperation {
   
    var metadata: tableMetadata
    
    init(metadata: tableMetadata) {
        self.metadata = metadata
    }
    
    override func start() {

        if isCancelled {
            self.finish()
        } else {
            let serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName
            let requestBody =
            """
            <?xml version=\"1.0\" encoding=\"UTF-8\"?>
            <d:propfind xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\">
            <d:prop>
                <has-preview xmlns=\"http://nextcloud.org/ns\"/>
                <creation_time xmlns=\"http://nextcloud.org/ns\"/>
                <upload_time xmlns=\"http://nextcloud.org/ns\"/>
            </d:prop>
            </d:propfind>
            """
            
            NCCommunication.shared.readFileOrFolder(serverUrlFileName: serverUrlFileName, depth: "0", requestBody: requestBody.data(using: .utf8)) { (account, files, responseData, errorCode, errorDescription) in
                if errorCode == 0 && files.count > 0 {
                    let file = files[0]
                    let metadata = tableMetadata.init(value: self.metadata)
                    var modify = false
                    if metadata.hasPreview != file.hasPreview {
                        metadata.hasPreview = file.hasPreview
                        modify = true
                    }
                    if file.creationDate != nil && metadata.creationDate != file.creationDate {
                        metadata.creationDate = file.creationDate!
                        modify = true
                    }
                    if file.uploadDate != nil && metadata.uploadDate != file.uploadDate {
                        metadata.uploadDate = file.uploadDate!
                        modify = true
                    }
                    if modify {
                        NCManageDatabase.sharedInstance.addMetadata(metadata)
                        NCOperationQueue.shared.reloadDataSourceMedia()
                    }
                } else if errorCode == 404 {
                    NCManageDatabase.sharedInstance.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", self.metadata.ocId))
                    NotificationCenter.default.postOnMainThread(name: k_notificationCenter_deleteFile, userInfo: ["metadata": self.metadata, "errorCode": errorCode])
                }
                self.finish()
            }
        }
    }
}



