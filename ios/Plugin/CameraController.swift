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

    /*
     Warm up the camera by pre-configuring cameras in the background.
     */
    public func warmUp() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self, granted else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                // Create and configure capture session if needed
                if self.captureSession == nil {
                    self.captureSession = AVCaptureSession()
                    self.captureSession?.sessionPreset = .photo
                }

                guard let session = self.captureSession else { return }

                // Configure preview layer on main thread
                DispatchQueue.main.async {
                    self.previewLayer.session = session
                    self.previewLayer.videoGravity = .resizeAspectFill
                }

                // Discover cameras
                let _ = self.discoverCameraDevices()

                // Setup input for the first available camera
                do {
                    guard let device = self.rearCamera ?? self.frontCamera else { return }
                    self.currentCamera = device
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                    }
                    self.cameraInput = input
                } catch {
                    // Silent failure is acceptable during warm up
                }

                // Pre configure photo output
                self.configurePhotoOutput(true)
            }
        }
    }

    public func prepare(cameraPosition: CameraPosition?, enableHighResolution isHighResolutionPhotoEnabled: Bool, completionHandler: @escaping (Error?) -> Void) {
        // Set up capture session
        let captureSession: AVCaptureSession
        if let existingSession = self.captureSession {
            captureSession = existingSession
        } else {
            captureSession = AVCaptureSession()
            self.captureSession = captureSession
            captureSession.sessionPreset = .photo
        }

        // Start session immediately, configure in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Initialize devices and input sequentially
            do {
                // try self.initializeCameraDevices(forPosition: cameraPosition ?? .rear)
                // try self.initializeCameraInput()

                // Start session before additional configuration
                captureSession.startRunning()
                let currentCamera = self.currentCamera!
                configureDeviceSettings(for: currentCamera)

                // Notify UI that camera is running (can show preview)
                DispatchQueue.main.async {
                    completionHandler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    completionHandler(error)
                }
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
        // If devices are already discovered, just set the current camera and return
        if self.rearCamera != nil && self.frontCamera != nil {
            self.currentCamera = cameraPosition == .rear ? rearCamera : frontCamera
            return
        }

        // Discover camera devices
        if !self.discoverCameraDevices() {
            throw CameraControllerError.noCamerasAvailable
        }

        // Set current camera
        self.currentCamera = cameraPosition == .rear ? rearCamera : frontCamera

        guard self.currentCamera != nil else {
            throw CameraControllerError.noCamerasAvailable
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

    /**
     Configure photo output settings
     */
    private func configurePhotoOutput(_ isHighResolutionPhotoEnabled: Bool) {
        guard let captureSession = captureSession else { return }
        if captureSession.outputs.contains(self.photoOutput) { return }

        self.photoOutput.setPreparedPhotoSettingsArray(
            [AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])],
            completionHandler: nil
        )
        self.photoOutput.isHighResolutionCaptureEnabled = isHighResolutionPhotoEnabled

        captureSession.beginConfiguration()
        if captureSession.canAddOutput(self.photoOutput) {
            captureSession.addOutput(self.photoOutput)
        }
        captureSession.commitConfiguration()
    }

    /**
     Configure camera device settings for focus, exposure, and zoom.
     */
    private func configureDeviceSettings(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            // Set appropriate zoom factor for triple camera
            if device.deviceType == .builtInTripleCamera {
                device.videoZoomFactor = 2.0
            }

            // Set focus mode
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            // Set exposure mode
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            device.unlockForConfiguration()
        } catch {
            // Silent failure is acceptable during setup
        }
    }

    /*
     Stop the camera session and release resources.
     */
    public func stop() {
       self?.captureSession?.stopRunning()
    }

    /**
     Discovers and initializes camera devices.
     Returns true if devices were successfully discovered.
     */
    private func discoverCameraDevices() -> Bool {
        // Only create discovery session if needed
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )

        // Get all devices at once
        let devices = discoverySession.devices

        // Find front and back cameras
        self.rearCamera = devices.first(where: { $0.position == .back })
        self.frontCamera = devices.first(where: { $0.position == .front })

        return self.rearCamera != nil || self.frontCamera != nil
    }

    public func displayPreview(on view: UIView) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            self.previewLayer.frame = view.bounds
            view.layer.insertSublayer(self.previewLayer, at: 0)

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

    private func updateFocusAndExposure(for device: AVCaptureDevice, at point: CGPoint) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = point
                device.focusMode = focusMode
            }

            let exposureMode: AVCaptureDevice.ExposureMode = .continuousAutoExposure
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = point
                device.exposureMode = exposureMode
            }
        } catch {
            debugPrint(error)
        }
    }

    @objc func handleTap(_ tap: UITapGestureRecognizer) {
        guard let device = self.currentCamera, let view = tap.view else { return }
        let tapPoint = tap.location(in: view)
        let devicePoint = self.previewLayer.captureDevicePointConverted(fromLayerPoint: tapPoint)
        updateFocusAndExposure(for: device, at: devicePoint)
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
