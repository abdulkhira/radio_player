/*
 *  RadioPlayer.swift
 *
 *  Created by Ilia Chirkunov <xc@yar.net> on 10.01.2021.
 */

import MediaPlayer
import AVKit

class RadioPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private var player: AVPlayer!
    private var playerItem: AVPlayerItem!
    var defaultArtwork: UIImage?
    var metadataArtwork: UIImage?
    var currentMetadata: Array<String>!
    var streamTitle: String!
    var streamUrl: String!
    var artWorkUrl: String!
    var ignoreIcy: Bool = false
    var itunesArtworkParser: Bool = true
    var interruptionObserverAdded: Bool = false
    var isPremiumUser: Bool = false

    func setMediaItem() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: streamTitle, ]
        defaultArtwork = nil
        metadataArtwork = nil
        playerItem = AVPlayerItem(url: URL(string: streamUrl)!)

        if (player == nil) {
            // Create an AVPlayer.
            player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = true
            player.addObserver(self, forKeyPath: #keyPath(AVPlayer.timeControlStatus), options: [.new], context: nil)
            runInBackground()
        } else {
            player.replaceCurrentItem(with: playerItem)
        }

        // Set interruption handler.
        if (!interruptionObserverAdded) {
            NotificationCenter.default.addObserver(self, selector: #selector(playerItemFailedToPlay), name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
            interruptionObserverAdded = true
        }

        // Set metadata handler.
        let metaOutput = AVPlayerItemMetadataOutput(identifiers: nil)
        metaOutput.setDelegate(self, queue: DispatchQueue.main)
        playerItem.add(metaOutput)
    }

    func setMetadata(_ newMetadata: Array<String>) {
        // Check for duplicate metadata.
        if (currentMetadata == newMetadata) { return }
        currentMetadata = newMetadata

        // Prepare metadata string for display.
        var metadata = newMetadata.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Parse artwork from iTunes.
        if (metadata[2].isEmpty && isPremiumUser) {
            metadata[2] = parseArtworkFromItunes(metadata[0], metadata[1])
        }

        // Update the now playing info.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyArtist: metadata[0], MPMediaItemPropertyTitle: metadata[1], ]

        // Download and set album cover.
        metadataArtwork = downloadImage(metadata[2])
        setArtwork(metadataArtwork ?? defaultArtwork)


        // Send metadata to client.
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "metadata"), object: nil, userInfo: ["metadata": metadata])
    }

    /// Resume playback after phone call.
    @objc func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
        }
        if type == .began {

        } else if type == .ended {
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else {
                    return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }
        }
    }

    /// TODO: Attempt to reconnect when disconnecting.
    @objc func playerItemFailedToPlay(_ notification: Notification) {

    }

    func setArtwork(_ image: UIImage?) {
        guard let image = image else { return }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { (size) -> UIImage in image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?.updateValue(artwork, forKey: MPMediaItemPropertyArtwork)
    }

    func play() {
        if player.currentItem == nil {
            player.replaceCurrentItem(with: playerItem) 
        } else if player.currentItem?.isPlaybackBufferEmpty == true || player.currentItem?.status == .failed {
            setMediaItem()
        } 

        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func pause() {
        player.pause()
    }

    func runInBackground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        try? AVAudioSession.sharedInstance().setCategory(.playback)

        // Control buttons on the lock screen.
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play button.
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] (event) -> MPRemoteCommandHandlerStatus in
            self?.play()
            return .success
        }

        // Pause button.
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] (event) -> MPRemoteCommandHandlerStatus in
            self?.pause()
            return .success
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let observedKeyPath = keyPath, object is AVPlayer, observedKeyPath == #keyPath(AVPlayer.timeControlStatus) else {
            return
        }

        if let statusAsNumber = change?[NSKeyValueChangeKey.newKey] as? NSNumber {
            let status = AVPlayer.TimeControlStatus(rawValue: statusAsNumber.intValue)

            if status == .paused {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "state"), object: nil, userInfo: ["state": false])
            } else if status == .waitingToPlayAtSpecifiedRate {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "state"), object: nil, userInfo: ["state": true])
            }
        }
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                from track: AVPlayerItemTrack?) {
        if (ignoreIcy) { return }

        var result: Array<String>!
        let rawMetadata = groups.first.map({ $0.items })

        // Parse title
        guard let title = rawMetadata?.first?.stringValue else { return }
        result = title.components(separatedBy: " - ")
        if (result.count == 1) { result.append("") }

        // Parse artwork
        rawMetadata!.count > 1 ? result.append(rawMetadata![1].stringValue!) : result.append("")

        // Update metadata
        if (isPremiumUser) {
            setMetadata(result)
        }
    }

    func downloadImage(_ value: String) -> UIImage? {
        guard let url = URL(string: value) else { return nil }

        var result: UIImage?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
            if let data = data, error == nil { 
                result = UIImage(data: data)
            }
            semaphore.signal()
        }
        task.resume()

        let _ = semaphore.wait(timeout: .distantFuture)
        return result
    }

    func parseArtworkFromItunes(_ artist: String, _ track: String) -> String {
        var artwork: String = ""

        if(artWorkUrl != nil && !artWorkUrl.isEmpty) {
            // guard let url = URL(string: "https://a8.asurahosting.com/public/deepnova/oembed/json") else {
            //     completion(nil)
            //     return
            // }

            // let task = URLSession.shared.dataTask(with: url) { data, response, error in
            //     guard
            //         let data = data,
            //         error == nil,
            //         let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            //         let thumbnailUrl = json["thumbnail_url"] as? String
            //     else {
            //         completion(nil)
            //         return
            //     }

            //     completion(thumbnailUrl)
            // }

            // task.resume()
              let semaphore = DispatchSemaphore(value: 0)

            // Step 1: Try AzuraCast
            if let azuraUrl = URL(string: artWorkUrl) {
                let task = URLSession.shared.dataTask(with: azuraUrl) { data, response, error in
                    if
                        let data = data,
                        error == nil,
                        let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                        let azuraArtwork = json["thumbnail_url"] as? String,
                        !azuraArtwork.isEmpty
                    {
                        artwork = azuraArtwork
                        semaphore.signal()
                        return
                    }

                    // // Fallback to iTunes if AzuraCast failed or empty
                    // if let fallback = fetchArtworkFromiTunesSync(artist: artist, track: track) {
                    //     artwork = fallback
                    // }
                    // semaphore.signal()
                }

                task.resume()
                semaphore.wait()
            }
        } else {
            // Generate a request.
            guard let term = (artist + " - " + track).addingPercentEncoding(withAllowedCharacters: .alphanumerics) 
            else { return artwork }

            guard let url = URL(string: "https://itunes.apple.com/search?term=" + term + "&limit=1")
            else { return artwork }

            // Download content.
            var jsonData: Data?
            let semaphore = DispatchSemaphore(value: 0)

            let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
                if let data = data, error == nil {
                    jsonData = data
                }
                semaphore.signal()
            }

            task.resume()
            let _ = semaphore.wait(timeout: .distantFuture)

            // Convert content to Dictonary.
            guard let jsonData = jsonData else { return artwork }
            guard let dict = try? JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String:Any]
            else { return artwork }

            // Make sure the result is found.
            guard let _ = dict["resultCount"], dict["resultCount"] as! Int > 0 else { return artwork }

            // Get artwork
            guard let results = dict["results"] as? Array<[String:Any]> else { return artwork }
            guard let artworkUrl30 = results[0]["artworkUrl30"] as? String else { return artwork }
            artwork = artworkUrl30.replacingOccurrences(of: "30x30bb", with: "500x500bb")
        }
        return artwork
    }
}
