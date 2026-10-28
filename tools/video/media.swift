// Native macOS encoding/muxing; no external media dependencies or downloaded assets.
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CoreVideo
import CoreText
let args = CommandLine.arguments
func finish(_ exporter: AVAssetExportSession) {
 let done = DispatchSemaphore(value:0)
 exporter.exportAsynchronously {done.signal()}; done.wait()
 guard exporter.status == .completed else {fatalError("Export: \(String(describing:exporter.error))")}
}
func line(_ text:String,_ size:CGFloat,_ x:CGFloat,_ y:CGFloat,_ context:CGContext) {
 let font = CTFontCreateWithName("Helvetica-Bold" as CFString,size,nil)
 let string = NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
 context.textPosition = CGPoint(x:x,y:y); CTLineDraw(CTLineCreateWithAttributedString(string),context)
}
if args[1] == "encode" {
 let raw = try FileHandle(forReadingFrom:URL(fileURLWithPath:args[2]))
 let index = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[3]))) as! [String:Any]
 let frames = index["frames"] as! [[Int]]
 let width = index["width"] as! Int, height = index["height"] as! Int
 let fps = index["fps"] as! Int
 let silent = URL(fileURLWithPath:args[4])
 let writer = try AVAssetWriter(outputURL:silent,fileType:.mp4)
 let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:14000000,AVVideoExpectedSourceFrameRateKey:fps,AVVideoMaxKeyFrameIntervalKey:fps,AVVideoAllowFrameReorderingKey:false]])
 input.expectsMediaDataInRealTime = false
 let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
 writer.add(input); guard writer.startWriting() else {fatalError("Writer failed")}
 writer.startSession(atSourceTime:.zero)
 for (i,entry) in frames.enumerated() {
  try autoreleasepool {
   while !input.isReadyForMoreMediaData {if writer.status == .failed {fatalError("Writer failed")};Thread.sleep(forTimeInterval:0.001)}
   try raw.seek(toOffset:UInt64(entry[0]));let data = try raw.read(upToCount:entry[1])!
   let source = CGImageSourceCreateWithData(data as CFData,nil)!
   let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
   var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
   let pixel = buffer!;CVPixelBufferLockBaseAddress(pixel,[])
   let context = CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue)!
   context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
   if i < fps*4 || args[7] == "CITY INVADERS" {
    let opacity = min(1.0,Double(i)/Double(fps)*3) * min(1.0,Double(frames.count-i)/Double(fps)*2)
    context.setAlpha(opacity)
    context.setFillColor(CGColor(gray:0.02,alpha:0.72));context.fill(CGRect(x:40,y:150,width:1150,height:125))
    line(args[7],44,65,218,context);line(args[8],25,65,173,context)
   }
   CVPixelBufferUnlockBaseAddress(pixel,[])
   guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(i),timescale:Int32(fps))) else {fatalError("Append failed")}
  }
 }
 input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:Int64(frames.count),timescale:Int32(fps)))
 let done = DispatchSemaphore(value:0);writer.finishWriting {done.signal()};done.wait()
 guard writer.status == .completed else {fatalError("Writer finish failed")}
 let composition = AVMutableComposition()
 let video = AVURLAsset(url:silent), sound = AVURLAsset(url:URL(fileURLWithPath:args[5]))
 let duration = CMTime(value:Int64(frames.count),timescale:Int32(fps))
 let v = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
 try v.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:video.tracks(withMediaType:.video)[0],at:.zero)
 guard let audio = sound.tracks(withMediaType:.audio).first else {fatalError("Missing audio")}
 let a = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
 try a.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:audio,at:.zero)
 let exporter = AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough)!
 exporter.outputURL = URL(fileURLWithPath:args[6]);exporter.outputFileType = .mp4;exporter.shouldOptimizeForNetworkUse = true;finish(exporter)
 print("Encoded \(frames.count) frames with audio")
} else if args[1] == "join" {
 let composition = AVMutableComposition()
 let v = composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
 let a = composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
 var cursor = CMTime.zero
 var instructions:[AVMutableVideoCompositionInstruction] = []
 let mix = AVMutableAudioMixInputParameters(track:a)
 let fade = CMTime(value:18,timescale:60)
 let audioFade = CMTime(value:8,timescale:60)
 for path in args.dropFirst(3) {
  let asset = AVURLAsset(url:URL(fileURLWithPath:path)), duration = AVURLAsset(url:URL(fileURLWithPath:path)).duration
  try v.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:asset.tracks(withMediaType:.video)[0],at:cursor)
  guard let sound = asset.tracks(withMediaType:.audio).first else {fatalError("Missing clip audio")}
  try a.insertTimeRange(CMTimeRange(start:.zero,duration:duration),of:sound,at:cursor)
  let end = CMTimeAdd(cursor,duration)
  let layer = AVMutableVideoCompositionLayerInstruction(assetTrack:v)
  layer.setOpacityRamp(fromStartOpacity:0,toEndOpacity:1,timeRange:CMTimeRange(start:cursor,duration:fade))
  layer.setOpacity(1,at:CMTimeAdd(cursor,fade))
  layer.setOpacityRamp(fromStartOpacity:1,toEndOpacity:0,timeRange:CMTimeRange(start:CMTimeSubtract(end,fade),duration:fade))
  let instruction = AVMutableVideoCompositionInstruction()
  instruction.timeRange = CMTimeRange(start:cursor,duration:duration)
  instruction.backgroundColor = CGColor(gray:0,alpha:1)
  instruction.layerInstructions = [layer];instructions.append(instruction)
  mix.setVolumeRamp(fromStartVolume:0,toEndVolume:1,timeRange:CMTimeRange(start:cursor,duration:audioFade))
  mix.setVolume(1,at:CMTimeAdd(cursor,audioFade))
  mix.setVolumeRamp(fromStartVolume:1,toEndVolume:0,timeRange:CMTimeRange(start:CMTimeSubtract(end,audioFade),duration:audioFade))
  cursor = end
 }
 let videoComposition = AVMutableVideoComposition()
 videoComposition.renderSize = CGSize(width:1920,height:1080)
 videoComposition.frameDuration = CMTime(value:1,timescale:60)
 videoComposition.instructions = instructions
 let audioMix = AVMutableAudioMix();audioMix.inputParameters = [mix]
 let exporter = AVAssetExportSession(asset:composition,presetName:AVAssetExportPreset1920x1080)!
 exporter.videoComposition = videoComposition;exporter.audioMix = audioMix
 exporter.outputURL = URL(fileURLWithPath:args[2]);exporter.outputFileType = .mp4;exporter.shouldOptimizeForNetworkUse = true;finish(exporter)
 print("Joined duration \(CMTimeGetSeconds(cursor)) with 0.3 s fades, 60 fps")
} else if args[1] == "audit" {
 let asset = AVURLAsset(url:URL(fileURLWithPath:args[2]))
 let video = asset.tracks(withMediaType:.video)[0]
 let reader = try AVAssetReader(asset:asset)
 let output = AVAssetReaderTrackOutput(track:video,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
 reader.add(output);reader.startReading();var count = 0
 while let sample = output.copyNextSampleBuffer() {if CMSampleBufferGetImageBuffer(sample) != nil {count += 1}}
 guard reader.status == .completed else {fatalError("Decode failed")}
 let report:[String:Any] = ["duration_s":CMTimeGetSeconds(asset.duration),"frames":count,"fps":video.nominalFrameRate,"width":video.naturalSize.width,"height":video.naturalSize.height,"audio_tracks":asset.tracks(withMediaType:.audio).count]
 print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
} else if args[1] == "frame" {
 let asset = AVURLAsset(url:URL(fileURLWithPath:args[2]))
 let generator = AVAssetImageGenerator(asset:asset)
 generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
 let image = try generator.copyCGImage(at:CMTime(seconds:Double(args[3])!,preferredTimescale:600),actualTime:nil)
 let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath:args[4]) as CFURL,"public.png" as CFString,1,nil)!
 CGImageDestinationAddImage(destination,image,nil);CGImageDestinationFinalize(destination)
}
