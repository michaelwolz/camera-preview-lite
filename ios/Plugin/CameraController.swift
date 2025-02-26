import AVFoundation
import UIKit

enum CameraControllerError: Swift.Error {
    case captureSessionAlreadyRunning
    case captureSessionIsMissing
    case inputsAreInvalid
    case invalidOperation
    case noCamerasAvailable
    case unknown
}

public enum CameraPosition {
    case front
    case rear
}

extension CameraControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .captureSessionAlreadyRunning:
            return NSLocalizedString("Capture Session is Already Running", comment: "Capture Session Already Running")
        case .captureSessionIsMissing:
            return NSLocalizedString("Capture Session is Missing", comment: "Capture Session Missing")
        case .inputsAreInvalid:
            return NSLocalizedString("Inputs Are Invalid", comment: "Inputs Are Invalid")
        case .invalidOperation:
            return NSLocalizedString("Invalid Operation", comment: "invalid Operation")
        case .noCamerasAvailable:
            return NSLocalizedString("Failed to access device camera(s)", comment: "No Cameras Available")
        case .unknown:
            return NSLocalizedString("Unknown", comment: "Unknown")

        }
    }
}

class CameraController: NSObject {
    var captureSession: AVCaptureSession?

    var photoOutput = AVCapturePhotoOutput()
    var photoCaptureCompletionBlock: ((UIImage?, Error?) -> Void)?
    var sampleBufferCaptureCompletionBlock: ((UIImage?, Error?) -> Void)?

    var previewLayer = AVCaptureVideoPreviewLayer()

    var frontCamera: AVCaptureDevice?
    var rearCamera: AVCaptureDevice?
    var currentCamera: AVCaptureDevice?
    var cameraInput: AVCaptureDeviceInput?

    var flashMode = AVCaptureDevice.FlashMode.off

    /** Video zoom factor that is used for manually zooming in and out via pinch gesture */
    var videoZoomFactor: CGFloat = 1

    public func prepare(cameraPosition: CameraPosition?, enableHighResolution isHighResolutionPhotoEnabled: Bool, completionHandler: @escaping (Error?) -> Void) {
        // Set up capture session
        let captureSession = AVCaptureSession()
        self.captureSession = captureSession

        // Use medium quality initially for faster startup, then upgrade if needed
        captureSession.sessionPreset = .medium

        // Set up preview layer immediately
        previewLayer.session = captureSession
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill

        // Initialize front and back camera
        do {
            try initializeCameraDevices(forPosition: cameraPosition ?? .rear)
            try initializeCameraInput()
        } catch {
            completionHandler(error)
            return
        }

        // Start the session immediately to show the preview faster
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()

            // Apply basic camera settings on background thread
            do {
                try self.configureCameraSettings()
            } catch {
                DispatchQueue.main.async {
                    completionHandler(error)
                }
                return
            }

            // Configure photo output and session preset in background
            captureSession.beginConfiguration()

            // Upgrade session preset if needed
            if (isHighResolutionPhotoEnabled) {
                captureSession.sessionPreset = .photo
            }

            // Configure camera output
            self.photoOutput.setPreparedPhotoSettingsArray([AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])], completionHandler: nil)
            self.photoOutput.isHighResolutionCaptureEnabled = isHighResolutionPhotoEnabled
            if captureSession.canAddOutput(self.photoOutput) {
                captureSession.addOutput(self.photoOutput)
            }

            captureSession.commitConfiguration()

            // Call completion handler on main thread
            DispatchQueue.main.async {
                completionHandler(nil)
            }
        }
    }

    public func stop() {
        // Perform cleanup on background thread to avoid UI blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()

            // Clear references for better memory management
            DispatchQueue.main.async { [weak self] in
                self?.previewLayer.session = nil
            }
        }
    }

    /**
     Initializes the available camera devices by selecting the best fit for the current iOS device.

     This method sets the current camera device to the requested one and also initializes the opposite camera for easy switching later.
     It configures virtual devices supporting ultra-wide angle and better autofocus to address several focus issues observed with newer iPhones.

     - Parameters:
     - cameraPosition: The position of the camera to initialize (front or rear).
     - Throws: `CameraControllerError.noCamerasAvailable` if no suitable camera is available.
     */
    private func initializeCameraDevices(forPosition cameraPosition: CameraPosition) throws {
        // Only initialize devices if they haven't been warmed up already
        if self.rearCamera == nil {
            if let rearCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                self.rearCamera = rearCamera
            } else {
                self.rearCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
        }

        if self.frontCamera == nil {
            self.frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }

        guard cameraPosition == .rear && rearCamera != nil || cameraPosition == .front && frontCamera != nil else {
            throw CameraControllerError.noCamerasAvailable
        }

        self.currentCamera = cameraPosition == .rear ? rearCamera : frontCamera
    }

    /**
     Configure several camera related properties based on the currently selected camera device.
     This function also keeps care of the default zoom factor for the chosen camera device
     */
    private func configureCameraSettings() throws {
        guard let cameraDevice = self.currentCamera else {
            throw CameraControllerError.noCamerasAvailable
        }

        // Only lock and configure if needed
        try cameraDevice.lockForConfiguration()
        defer { cameraDevice.unlockForConfiguration() }

        // Apply settings only if they aren't already set
        if cameraDevice.focusMode != .continuousAutoFocus && cameraDevice.isFocusModeSupported(.continuousAutoFocus) {
            cameraDevice.focusMode = .continuousAutoFocus
        }

        if cameraDevice.exposureMode != .continuousAutoExposure && cameraDevice.isExposureModeSupported(.continuousAutoExposure) {
            cameraDevice.exposureMode = .continuousAutoExposure
        }

        // Always ensure proper zoom for triple camera since position might have changed
        if cameraDevice.deviceType == .builtInTripleCamera && cameraDevice.videoZoomFactor != 2.0 {
            cameraDevice.videoZoomFactor = 2.0
        }
    }

    public func warmUpCamera() {
        // Pre-warm AVCaptureSession for faster startup when actually needed
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self, granted else { return }

            // Initialize camera devices in background with the same configuration as would be used later
            DispatchQueue.global(qos: .userInitiated).async {
                // Pre-initialize rear camera with triple camera if available
                if self.rearCamera == nil {
                    if let rearCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                        self.rearCamera = rearCamera
                    } else {
                        self.rearCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    }

                    // Pre-configure rear camera if available
                    if let device = self.rearCamera {
                        do {
                            try device.lockForConfiguration()

                            // Set focus and exposure modes
                            if device.isFocusModeSupported(.continuousAutoFocus) {
                                device.focusMode = .continuousAutoFocus
                            }

                            if device.isExposureModeSupported(.continuousAutoExposure) {
                                device.exposureMode = .continuousAutoExposure
                            }

                            // Set appropriate zoom factor for triple camera
                            if device.deviceType == .builtInTripleCamera {
                                device.videoZoomFactor = 2.0
                            }

                            device.unlockForConfiguration()
                        } catch {
                            // Silent failure during warm-up is acceptable
                        }
                    }
                }

                // Pre-initialize front camera
                if self.frontCamera == nil {
                    self.frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)

                    // Pre-configure front camera
                    if let device = self.frontCamera {
                        try? device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        device.unlockForConfiguration()
                    }
                }
            }
        }
    }

    /**
     Initialize the camera inputs
     */
    private func initializeCameraInput() throws {
        guard let captureSession = self.captureSession else { throw CameraControllerError.captureSessionIsMissing }

        guard let camera = self.currentCamera else { throw CameraControllerError.noCamerasAvailable }

        do {
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(cameraInput) {
                captureSession.addInput(cameraInput)
            }
            self.cameraInput = cameraInput
        } catch {
            throw CameraControllerError.noCamerasAvailable
        }
    }

    public func displayPreview(on view: UIView) {
        // Optimize layer insertion by using main thread and CATransaction
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true) // Avoid implicit animations

            view.layer.insertSublayer(self.previewLayer, at: 0)
            self.previewLayer.frame = view.frame

            CATransaction.commit()
            self.updateVideoOrientation()
        }
    }

    public func updateVideoOrientation() {
        assert(Thread.isMainThread)

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }

        let interfaceOrientation = windowScene.interfaceOrientation

        let videoOrientation: AVCaptureVideoOrientation
        switch interfaceOrientation {
        case .portrait:
            videoOrientation = .portrait
        case .landscapeLeft:
            videoOrientation = .landscapeLeft
        case .landscapeRight:
            videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .unknown:
            videoOrientation = .portrait
        @unknown default:
            videoOrientation = .portrait
        }

        previewLayer.connection?.videoOrientation = videoOrientation
        photoOutput.connections.forEach { $0.videoOrientation = videoOrientation }
    }

    public func switchCameras() throws {
        guard let captureSession = self.captureSession, captureSession.isRunning else { throw CameraControllerError.captureSessionIsMissing }
        guard let device = self.currentCamera else { throw CameraControllerError.noCamerasAvailable }

        let targetPosition: AVCaptureDevice.Position = (device.position == .front) ? .back : .front
        let targetDevice = (targetPosition == .front) ? self.frontCamera : self.rearCamera

        guard let newCamera = targetDevice else { throw CameraControllerError.noCamerasAvailable }

        // Prepare new input before configuration to minimize switching time
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: newCamera)
        } catch {
            throw CameraControllerError.invalidOperation
        }

        // Configure session
        captureSession.beginConfiguration()

        // Remove existing input
        if let cameraInput = self.cameraInput, captureSession.inputs.contains(cameraInput) {
            captureSession.removeInput(cameraInput)
        }

        // Add new input
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
            self.cameraInput = newInput
            self.currentCamera = newCamera
        } else {
            captureSession.commitConfiguration()
            throw CameraControllerError.invalidOperation
        }

        // Reconfigure camera settings
        captureSession.commitConfiguration()

        // Apply settings after configuration is committed
        try? self.configureCameraSettings()
    }

    func captureImage(completion: @escaping (UIImage?, Error?) -> Void) {
        guard let captureSession = captureSession, captureSession.isRunning else {
            completion(nil, CameraControllerError.captureSessionIsMissing);
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = self.flashMode

        self.photoOutput.capturePhoto(with: settings, delegate: self)
        self.photoCaptureCompletionBlock = completion
    }

    func captureSample(completion: @escaping (UIImage?, Error?) -> Void) {
        guard let captureSession = captureSession, captureSession.isRunning else {
            completion(nil, CameraControllerError.captureSessionIsMissing)
            return
        }

        self.sampleBufferCaptureCompletionBlock = completion
    }

    func getSupportedFlashModes() throws -> [String] {
        guard let device = self.currentCamera else { throw CameraControllerError.noCamerasAvailable }

        var supportedFlashModesAsStrings: [String] = []
        if device.hasFlash {
            for flashMode in self.photoOutput.supportedFlashModes {
                var flashModeValue: String?

                switch flashMode {
                case AVCaptureDevice.FlashMode.off:
                    flashModeValue = "off"
                case AVCaptureDevice.FlashMode.on:
                    flashModeValue = "on"
                case AVCaptureDevice.FlashMode.auto:
                    flashModeValue = "auto"
                default: break
                }

                if flashModeValue != nil {
                    supportedFlashModesAsStrings.append(flashModeValue!)
                }
            }
        }

        if device.hasTorch {
            supportedFlashModesAsStrings.append("torch")
        }

        return supportedFlashModesAsStrings
    }

    func setFlashMode(flashMode: AVCaptureDevice.FlashMode) throws {
        guard let device = self.currentCamera else { throw CameraControllerError.noCamerasAvailable }

        if !self.photoOutput.supportedFlashModes.contains(flashMode) {
            return
        }

        do {
            try device.lockForConfiguration()

            if device.hasTorch && device.isTorchAvailable && device.torchMode == AVCaptureDevice.TorchMode.on {
                device.torchMode = AVCaptureDevice.TorchMode.off
            }

            let photoSettings = AVCapturePhotoSettings()
            photoSettings.flashMode = flashMode

            self.flashMode = flashMode
            self.photoOutput.photoSettingsForSceneMonitoring = photoSettings

            device.unlockForConfiguration()
        } catch {
            throw CameraControllerError.invalidOperation
        }
    }

    func setTorchMode() throws {
        guard let device = self.currentCamera, device.hasTorch, device.isTorchAvailable else {
            throw CameraControllerError.invalidOperation
        }

        do {
            try device.lockForConfiguration()

            if device.isTorchModeSupported(AVCaptureDevice.TorchMode.on) {
                device.torchMode = AVCaptureDevice.TorchMode.on
            } else if device.isTorchModeSupported(AVCaptureDevice.TorchMode.auto) {
                device.torchMode = AVCaptureDevice.TorchMode.auto
            } else {
                device.torchMode = AVCaptureDevice.TorchMode.off
            }

            device.unlockForConfiguration()
        } catch {
            throw CameraControllerError.invalidOperation
        }
    }

    public func setupGestures(target: UIView, enableZoom: Bool) {
        setupTapGesture(target: target, selector: #selector(handleTap(_:)), delegate: self)
        if enableZoom {
            setupPinchGesture(target: target, selector: #selector(handlePinch(_:)), delegate: self)
        }
    }

    private func setupTapGesture(target: UIView, selector: Selector, delegate: UIGestureRecognizerDelegate?) {
        let tapGesture = UITapGestureRecognizer(target: self, action: selector)
        tapGesture.delegate = delegate
        target.addGestureRecognizer(tapGesture)
    }

    private func setupPinchGesture(target: UIView, selector: Selector, delegate: UIGestureRecognizerDelegate?) {
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: selector)
        pinchGesture.delegate = delegate
        target.addGestureRecognizer(pinchGesture)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error = error {
            self.photoCaptureCompletionBlock?(nil, error)
            return
        }

        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            self.photoCaptureCompletionBlock?(nil, CameraControllerError.unknown)
            return
        }

        self.photoCaptureCompletionBlock?(image.fixedOrientation(), nil)
    }
}

extension CameraController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc func handleTap(_ tap: UITapGestureRecognizer) {
        guard let device = self.currentCamera else { return }

        let point = tap.location(in: tap.view)
        let devicePoint = self.previewLayer.captureDevicePointConverted(fromLayerPoint: point)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let focusMode = AVCaptureDevice.FocusMode.continuousAutoFocus
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = CGPoint(x: CGFloat(devicePoint.x), y: CGFloat(devicePoint.y))
                device.focusMode = focusMode
            }

            let exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = CGPoint(x: CGFloat(devicePoint.x), y: CGFloat(devicePoint.y))
                device.exposureMode = exposureMode
            }
        } catch {
            debugPrint(error)
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard let device = self.currentCamera else { return }

        func minMaxZoom(_ factor: CGFloat) -> CGFloat {
            return max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        }

        func update(scale factor: CGFloat) {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                device.videoZoomFactor = factor
            } catch {
                debugPrint(error)
            }
        }

        switch pinch.state {
        case .began: fallthrough
        case .changed:
            let newScaleFactor = minMaxZoom(pinch.scale)
            update(scale: newScaleFactor)
        case .ended:
            videoZoomFactor = device.videoZoomFactor
        default: break
        }
    }
}
