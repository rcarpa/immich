import Accelerate
import Flutter
import ImageIO
import MobileCoreServices
import Photos

final class RemoteImageRequest: ImageRequest {
  var task: URLSessionDataTask?
  let id: Int64
  /// Lets cancellation stop a native decode partway through.
  let decodeCancelled = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

  init(id: Int64, completion: @escaping @Sendable (Result<[String: Int64]?, any Error>) -> Void) {
    self.id = id
    super.init(completion: completion)
    decodeCancelled.initialize(to: false)
  }

  deinit {
    decodeCancelled.deallocate()
  }

  override func cancel() {
    super.cancel()
    task?.cancel()
    NativeCore.cancel(decodeCancelled)
  }
}

class RemoteImageApiImpl: NSObject, RemoteImageApi {
  private static let registry = RequestRegistry<RemoteImageRequest>()
  private static let rgbaFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    renderingIntent: .perceptual
  )!
  private static let decodeOptions: [NSString: Bool] = [
    kCGImageSourceShouldCache: false,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceCreateThumbnailFromImageAlways: true
  ]

  func requestImage(url: String, requestId: Int64, preferEncoded: Bool, width: Int64?, height: Int64?, completion: @escaping (Result<[String : Int64]?, any Error>) -> Void) {
    let request = RemoteImageRequest(id: requestId, completion: completion)
    Self.registry.add(requestId: requestId, request: request)

    // immich-sync fork: serve from the offline store when it has the file. Only an in-memory lookup on the main
    // thread; the read runs on the store's queue.
    let name = OfflineStore.fileName(for: url)
    if let name, OfflineStore.mightHold(name) {
      OfflineStore.io.async {
        if request.isCancelled {
          return request.completion(ImageProcessing.cancelledResult)
        }
        guard let stored = OfflineStore.data(name: name) else {
          return Self.fetch(url: url, name: name, request: request, encoded: preferEncoded, width: width, height: height)
        }
        ImageProcessing.queue.addOperation {
          if request.isCancelled {
            return request.completion(ImageProcessing.cancelledResult)
          }
          Self.handleCompletion(request: request, encoded: preferEncoded, width: width, height: height, data: stored, response: nil, error: nil)
        }
      }
      return
    }

    Self.fetch(url: url, name: name, request: request, encoded: preferEncoded, width: width, height: height)
  }

  /// immich-sync fork: the network path. What comes back is kept in the offline store.
  private static func fetch(url: String, name: String?, request: RemoteImageRequest, encoded: Bool, width: Int64?, height: Int64?) {
    guard let parsed = URL(string: url) else {
      registry.remove(requestId: request.id)
      return request.completion(.failure(PigeonError(code: "", message: "Invalid image URL", details: nil)))
    }

    var urlRequest = URLRequest(url: parsed)
    // immich-sync fork: the store keeps image bytes, so URLCache does not.
    urlRequest.cachePolicy = name == nil ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData

    let task = URLSessionManager.shared.session.dataTask(with: urlRequest) { data, response, error in
      if let name, let data, error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
        OfflineStore.keepsType(response?.mimeType)
      {
        OfflineStore.store(data, name: name)
      }
      handleCompletion(request: request, encoded: encoded, width: width, height: height, data: data, response: response, error: error)
    }

    request.task = task
    // Resume even if cancelled meanwhile: that still delivers the completion, which answers the request once.
    if request.isCancelled {
      task.cancel()
    }
    task.resume()
  }

  private static func handleCompletion(request: RemoteImageRequest, encoded: Bool, width: Int64?, height: Int64?, data: Data?, response: URLResponse?, error: Error?) {
    if request.isCancelled {
      return request.completion(ImageProcessing.cancelledResult)
    }

    if let error = error {
      registry.remove(requestId: request.id)
      return request.completion(.failure(error))
    }

    guard let data = data else {
      registry.remove(requestId: request.id)
      return request.completion(.failure(PigeonError(code: "", message: "No data received", details: nil)))
    }

    // Flutter can't decode JPEG XL and older iOS versions can't either, so this applies to encoded requests too.
    // immich-sync fork: a stored file has no response, so JPEG XL is told by its signature.
    if response?.mimeType == "image/jxl" || (response == nil && OfflineStore.isJxl(data)) {
      ImageProcessing.queue.addOperation {
        if request.isCancelled {
          return request.completion(ImageProcessing.cancelledResult)
        }

        guard let (width, height, pointer) = NativeCore.decodeImage(data, targetWidth: width, targetHeight: height, maxPixelSize: ImageProcessing.maxPixelSize, cancelled: request.decodeCancelled) else {
          registry.remove(requestId: request.id)
          if request.isCancelled {
            return request.completion(ImageProcessing.cancelledResult)
          }
          return request.completion(.failure(PigeonError(code: "", message: "Failed to decode JPEG XL image", details: nil)))
        }

        if request.isCancelled {
          free(pointer)
          return request.completion(ImageProcessing.cancelledResult)
        }

        registry.remove(requestId: request.id)
        request.completion(
          .success([
            "pointer": Int64(Int(bitPattern: pointer)),
            "width": Int64(width),
            "height": Int64(height),
            "rowBytes": Int64(width * 4),
          ]))
      }
      return
    }

    if encoded {
      let length = data.count
      let pointer = malloc(length)!
      data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: length)

      if request.isCancelled {
        free(pointer)
        return request.completion(ImageProcessing.cancelledResult)
      }

      registry.remove(requestId: request.id)
      return request.completion(
        .success([
          "pointer": Int64(Int(bitPattern: pointer)),
          "length": Int64(length),
        ]))
    }

    ImageProcessing.queue.addOperation {
      if request.isCancelled {
        return request.completion(ImageProcessing.cancelledResult)
      }

      guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
        registry.remove(requestId: request.id)
        return request.completion(.failure(PigeonError(code: "", message: "Failed to decode image for request", details: nil)))
      }

      var options: [NSString: Any] = decodeOptions
      if let maxPixelSize = targetThumbnailRenderSize(imageSource: imageSource, width: width, height: height) {
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
      }

      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
        registry.remove(requestId: request.id)
        return request.completion(.failure(PigeonError(code: "", message: "Failed to decode image for request", details: nil)))
      }

      if request.isCancelled {
        return request.completion(ImageProcessing.cancelledResult)
      }

      do {
        let buffer = try vImage_Buffer(cgImage: cgImage, format: rgbaFormat)

        if request.isCancelled {
          buffer.free()
          return request.completion(ImageProcessing.cancelledResult)
        }

        registry.remove(requestId: request.id)
        return request.completion(
                 .success([
                   "pointer": Int64(Int(bitPattern: buffer.data)),
                   "width": Int64(buffer.width),
                   "height": Int64(buffer.height),
                   "rowBytes": Int64(buffer.rowBytes),
                 ]))
      } catch {
        registry.remove(requestId: request.id)
        return request.completion(.failure(PigeonError(code: "", message: "Failed to convert image for request: \(error)", details: nil)))
      }
    }
  }

  /// Returns the longest rendered edge needed to cover the requested size.
  private static func targetThumbnailRenderSize(imageSource: CGImageSource, width: Int64?, height: Int64?) -> Int? {
    guard let width,
          let height,
          width > 0,
          height > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let pixelWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let pixelHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
      return nil
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
      .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
    let swapsDimensions: Bool
    switch orientation {
    case .leftMirrored, .right, .rightMirrored, .left:
      swapsDimensions = true
    default:
      swapsDimensions = false
    }
    let sourceWidth = swapsDimensions ? pixelHeight.doubleValue : pixelWidth.doubleValue
    let sourceHeight = swapsDimensions ? pixelWidth.doubleValue : pixelHeight.doubleValue
    let fillScale = max(Double(width) / sourceWidth, Double(height) / sourceHeight)
    let scale = min(1, fillScale)
    return scale < 1 ? Int(ceil(max(sourceWidth * scale, sourceHeight * scale))) : nil
  }

  func cancelRequest(requestId: Int64) {
    Self.registry.remove(requestId: requestId)?.cancel()
  }

  func clearCache(completion: @escaping (Result<Int64, any Error>) -> Void) {
    Task {
      let cache = URLSessionManager.shared.session.configuration.urlCache!
      let cacheSize = Int64(cache.currentDiskUsage)
      cache.removeAllCachedResponses()
      completion(.success(cacheSize))
    }
  }
}
