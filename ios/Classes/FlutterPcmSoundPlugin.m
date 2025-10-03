#import "FlutterPcmSoundPlugin.h"
#import <AudioToolbox/AudioToolbox.h>

#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#endif

#define kOutputBus 0
#define NAMESPACE @"flutter_pcm_sound"

typedef NS_ENUM(NSUInteger, LogLevel) {
    none = 0,
    error = 1,
    standard = 2,
    verbose = 3,
};

@interface FlutterPcmSoundPlugin ()
@property(nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic) FlutterMethodChannel *mMethodChannel;
@property(nonatomic) LogLevel mLogLevel;
@property(nonatomic) AudioComponentInstance mAudioUnit;
@property(nonatomic) NSMutableData *mSamples;
@property(nonatomic) int mNumChannels;
@property(nonatomic) int mFeedThreshold;
@property(nonatomic) bool mDidInvokeFeedCallback;
@property(nonatomic) bool mDidSendZero;
@property(nonatomic) bool mDidSetup;
@property(nonatomic) BOOL mIsAppActive;
@property(nonatomic) BOOL mAllowBackgroundAudio;
// The software gate flag, equivalent to the Android version.
@property(nonatomic) BOOL _isPlaying;

@end

@implementation FlutterPcmSoundPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
{
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:NAMESPACE @"/methods"
                                                                    binaryMessenger:[registrar messenger]];

    FlutterPcmSoundPlugin *instance = [[FlutterPcmSoundPlugin alloc] init];
    instance.mMethodChannel = methodChannel;
    instance.mLogLevel = verbose;
    instance.mSamples = [NSMutableData new];
    instance.mFeedThreshold = 8000;
    instance.mDidInvokeFeedCallback = false;
    instance.mDidSendZero = false;
    instance.mDidSetup = false;
    instance.mIsAppActive = true;
    instance.mAllowBackgroundAudio = false;

#if TARGET_OS_IOS
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:instance selector:@selector(onWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:instance selector:@selector(onDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
#endif

    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

#if TARGET_OS_IOS
- (void)onWillResignActive:(NSNotification *)note {
  self.mIsAppActive = NO;
}

- (void)onDidBecomeActive:(NSNotification *)note {
  self.mIsAppActive = YES;
}
#endif

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result
{
    @try
    {
        if ([@"setLogLevel" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *logLevelNumber  = args[@"log_level"];
            self.mLogLevel = (LogLevel)[logLevelNumber integerValue];
            result(@YES);
        }
        else if ([@"setup" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *sampleRate       = args[@"sample_rate"];
            NSNumber *numChannels      = args[@"num_channels"];
#if TARGET_OS_IOS
            self.mAllowBackgroundAudio = [args[@"ios_allow_background_audio"] boolValue];
#endif

            self.mNumChannels = [numChannels intValue];

            if (_mAudioUnit != nil) {
                [self cleanup];
            }

            AudioComponentDescription desc;
            desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IOS
            desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else // MacOS
            desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
            desc.componentFlags = 0;
            desc.componentFlagsMask = 0;
            desc.componentManufacturer = kAudioUnitManufacturer_Apple;

            AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
            OSStatus status = AudioComponentInstanceNew(inputComponent, &_mAudioUnit);
            if (status != noErr) {
                result([FlutterError errorWithCode:@"AudioUnitError" message:@"AudioComponentInstanceNew failed" details:nil]);
                return;
            }

            AudioStreamBasicDescription audioFormat;
            audioFormat.mSampleRate = [sampleRate intValue];
            audioFormat.mFormatID = kAudioFormatLinearPCM;
            audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
            audioFormat.mFramesPerPacket = 1;
            audioFormat.mChannelsPerFrame = self.mNumChannels;
            audioFormat.mBitsPerChannel = 16;
            audioFormat.mBytesPerFrame = self.mNumChannels * (audioFormat.mBitsPerChannel / 8);
            audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame * audioFormat.mFramesPerPacket;

            status = AudioUnitSetProperty(_mAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, sizeof(audioFormat));
            if (status != noErr) {
                result([FlutterError errorWithCode:@"AudioUnitError" message:@"AudioUnitSetProperty StreamFormat failed" details:nil]);
                return;
            }

            AURenderCallbackStruct callback;
            callback.inputProc = RenderCallback;
            callback.inputProcRefCon = (__bridge void *)(self);

            status = AudioUnitSetProperty(_mAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &callback, sizeof(callback));
            if (status != noErr) {
                result([FlutterError errorWithCode:@"AudioUnitError" message:@"AudioUnitSetProperty SetRenderCallback failed" details:nil]);
                return;
            }

            status = AudioUnitInitialize(_mAudioUnit);
            if (status != noErr) {
                result([FlutterError errorWithCode:@"AudioUnitError" message:@"AudioUnitInitialize failed" details:nil]);
                return;
            }

            // --- IMPROVEMENT ---
            // Start the AudioUnit once and let it run. It will pull data from the RenderCallback.
            // This avoids the overhead of starting/stopping the hardware.
            status = AudioOutputUnitStart(_mAudioUnit);
            if (status != noErr) {
                result([FlutterError errorWithCode:@"AudioUnitError" message:@"AudioOutputUnitStart failed" details:nil]);
                return;
            }

            self.mDidSetup = true;
            self._isPlaying = NO; // Initialize in a stopped state.
            
            result(@YES);
        }
        else if ([@"feed" isEqualToString:call.method])
        {
            if (self.mDidSetup == false) {
                result([FlutterError errorWithCode:@"Setup" message:@"must call setup first" details:nil]);
                return;
            }

            NSDictionary *args = (NSDictionary*)call.arguments;
            FlutterStandardTypedData *buffer = args[@"buffer"];

            @synchronized (self.mSamples) {
                [self.mSamples appendData:buffer.data];
            }
            
            self.mDidInvokeFeedCallback = false;
            self.mDidSendZero = false;

            // --- IMPROVEMENT ---
            // We no longer start the AudioUnit here. The 'feed' method's only job
            // is to provide data, just like the Android version.
            
            result(@YES);
        }
        else if ([@"start" isEqualToString:call.method])
        {
            // --- IMPROVEMENT ---
            // We no longer call AudioOutputUnitStart. The unit is already running.
            // We just flip the software flag to allow the RenderCallback to provide data.
            if (self.mAudioUnit != nil && !self._isPlaying) {
                self._isPlaying = YES;
            }
            result(@YES);
        }
        else if ([@"stop" isEqualToString:call.method])
        {
            // --- IMPROVEMENT ---
            // This is the software gate. We do NOT stop the AudioUnit.
            // We just set the flag and clear the buffer to stop sound immediately.
            // This prevents the hardware-induced delay on restart.
            if (self.mAudioUnit != nil && self._isPlaying) {
                self._isPlaying = NO;
                @synchronized (self.mSamples) {
                    [self.mSamples setLength:0];
                }
            }
            result(@YES);
        }
        else if ([@"setFeedThreshold" isEqualToString:call.method])
        {
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSNumber *feedThreshold = args[@"feed_threshold"];
            self.mFeedThreshold = [feedThreshold intValue];
            result(@YES);
        }
        else if([@"release" isEqualToString:call.method])
        {
            [self cleanup];
            result(@YES);
        }
        else
        {
            result([FlutterError errorWithCode:@"functionNotImplemented" message:call.method details:nil]);
        }
    }
    @catch (NSException *e)
    {
        NSString *stackTrace = [[e callStackSymbols] componentsJoinedByString:@"\n"];
        result([FlutterError errorWithCode:@"iosException" message:[e reason] details:@{@"stackTrace": stackTrace}]);
    }
}

- (void)cleanup
{
    if (_mAudioUnit != nil) {
        // This is the correct place to fully stop and dispose of the AudioUnit.
        AudioOutputUnitStop(_mAudioUnit);
        AudioUnitUninitialize(_mAudioUnit);
        AudioComponentInstanceDispose(_mAudioUnit);
        _mAudioUnit = nil;
        self.mDidSetup = false;
        self._isPlaying = NO;
    }
    @synchronized (self.mSamples) {
        self.mSamples = [NSMutableData new];
    }
}

// --- IMPROVEMENT ---
// The RenderCallback is the heart of the software gating logic.
static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData)
{
    FlutterPcmSoundPlugin *instance = (__bridge FlutterPcmSoundPlugin *)(inRefCon);

    @synchronized (instance.mSamples) {
        // First, check the software gate flag.
        if (instance._isPlaying && [instance.mSamples length] > 0) {
            // If playing, copy as much data as we have, up to the buffer size.
            NSUInteger bytesToCopy = MIN(ioData->mBuffers[0].mDataByteSize, [instance.mSamples length]);
            memcpy(ioData->mBuffers[0].mData, [instance.mSamples bytes], bytesToCopy);

            // Remove the copied data from our buffer.
            NSRange range = NSMakeRange(0, bytesToCopy);
            [instance.mSamples replaceBytesInRange:range withBytes:NULL length:0];
            
            // If we didn't have enough data to fill the buffer, fill the rest with silence.
            if (bytesToCopy < ioData->mBuffers[0].mDataByteSize) {
                memset(ioData->mBuffers[0].mData + bytesToCopy, 0, ioData->mBuffers[0].mDataByteSize - bytesToCopy);
            }
        } else {
            // If not playing or no data, provide silence. The AudioUnit keeps running.
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }

        // --- Callback logic for requesting more data ---
        NSUInteger remainingFrames = [instance.mSamples length] / (instance.mNumChannels * sizeof(short));
        BOOL isThresholdEvent = remainingFrames <= instance.mFeedThreshold && !instance.mDidInvokeFeedCallback;
        BOOL isZeroCrossingEvent = instance.mDidSendZero == false && remainingFrames == 0;

        if (isThresholdEvent || isZeroCrossingEvent) {
            instance.mDidInvokeFeedCallback = true;
            instance.mDidSendZero = remainingFrames == 0;
            NSDictionary *response = @{@"remaining_frames": @(remainingFrames)};
            dispatch_async(dispatch_get_main_queue(), ^{
                [instance.mMethodChannel invokeMethod:@"OnFeedSamples" arguments:response];
            });
        }
    }
    return noErr;
}

@end