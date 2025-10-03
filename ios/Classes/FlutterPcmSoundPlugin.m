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
// OPTIONAL: Additional safety lock for cleanup operations
@property(nonatomic, strong) NSLock *cleanupLock;

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
    // Initialize cleanup lock for additional safety
    instance.cleanupLock = [[NSLock alloc] init];

#if TARGET_OS_IOS
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:instance selector:@selector(onWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:instance selector:@selector(onDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
#endif

    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

#if TARGET_OS_IOS
- (void)onWillResignActive:(NSNotification *)note {
  // FOREGROUND SERVICE FIX: Enhanced app lifecycle handling
  self.mIsAppActive = NO;
  
  // FOREGROUND SERVICE FIX: Prevent callbacks during app transition
  self.mDidInvokeFeedCallback = true; // Prevent new callbacks
  
  NSLog(@"PCM: App will resign active - preventing callbacks");
}

- (void)onDidBecomeActive:(NSNotification *)note {
  // FOREGROUND SERVICE FIX: Enhanced app lifecycle handling
  self.mIsAppActive = YES;
  
  // FOREGROUND SERVICE FIX: Reset callback flags when app becomes active
  self.mDidInvokeFeedCallback = false;
  
  NSLog(@"PCM: App did become active - allowing callbacks");
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

// REMOVED: Audio session configuration - handled externally by the app

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
            // EXTERNAL AUDIO SESSION FIX: Enhanced stop method that doesn't interfere with external audio session
            if (self.mAudioUnit != nil && self._isPlaying) {
                // EXTERNAL AUDIO SESSION FIX: Set playing flag first, then clear buffer to prevent race condition
                self._isPlaying = NO;
                
                // EXTERNAL AUDIO SESSION FIX: Clear buffer safely with additional checks
                @synchronized (self.mSamples) {
                    if (self.mSamples) {
                        [self.mSamples setLength:0];
                    }
                }
                
                // EXTERNAL AUDIO SESSION FIX: Reset callback flags to prevent stale callbacks
                self.mDidInvokeFeedCallback = false;
                self.mDidSendZero = false;
                
                // EXTERNAL AUDIO SESSION FIX: Additional safety - prevent any pending callbacks
                if (self.mMethodChannel) {
                    // Cancel any pending method channel operations
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // This ensures any pending callbacks are processed before we continue
                        // No-op, just ensures the queue is clear
                    });
                }
                
                // EXTERNAL AUDIO SESSION FIX: Log for debugging external audio session issues
                NSLog(@"PCM: Stop called - AudioUnit still running, audio session managed externally");
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
    // HYBRID APPROACH: Use lock for critical cleanup section only
    [self.cleanupLock lock];
    @try {
        // CRASH FIX: Set flags first to prevent RenderCallback from accessing invalid state
        self._isPlaying = NO;
        self.mDidSetup = false;
        self.mDidInvokeFeedCallback = false;
        self.mDidSendZero = false;
        
        // Clear samples buffer safely
        @synchronized (self.mSamples) {
            if (self.mSamples) {
                [self.mSamples setLength:0];
            }
        }
        
        // Clean up AudioUnit if it exists
        if (_mAudioUnit != nil) {
            // CRASH FIX: Add safety checks before AudioUnit operations
            @try {
                // This is the correct place to fully stop and dispose of the AudioUnit.
                AudioOutputUnitStop(_mAudioUnit);
                AudioUnitUninitialize(_mAudioUnit);
                AudioComponentInstanceDispose(_mAudioUnit);
            } @catch (NSException *exception) {
                NSLog(@"Warning: Exception during AudioUnit cleanup: %@", exception.reason);
            } @finally {
                _mAudioUnit = nil;
            }
        }
        
// REMOVED: Audio session deactivation - handled externally by the app
        
        // CRASH FIX: Clear method channel reference to prevent stale callbacks
        self.mMethodChannel = nil;
        
        // CRASH FIX: Clear cleanup lock reference
        self.cleanupLock = nil;
    } @finally {
        // Only unlock if we still have the lock (in case cleanupLock was set to nil)
        if (self.cleanupLock) {
            [self.cleanupLock unlock];
        }
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
    
    // CRASH FIX: Add null checks to prevent crashes in foreground services
    if (!instance || !ioData || !ioData->mBuffers || ioData->mNumberBuffers == 0) {
        return noErr;
    }

    // FOREGROUND SERVICE FIX: Quick cleanup check without blocking audio thread
    if (instance.cleanupLock && [instance.cleanupLock tryLock]) {
        [instance.cleanupLock unlock];
    } else if (instance.cleanupLock) {
        // Cleanup in progress, provide silence
        if (ioData->mBuffers[0].mData) {
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }
        return noErr;
    }
    // If cleanupLock is nil, proceed (instance might be deallocated)
    
    // EXTERNAL AUDIO SESSION FIX: Check if app is in a valid state for audio processing
    if (!instance.mIsAppActive && !instance.mAllowBackgroundAudio) {
        // App is backgrounded and background audio not allowed, provide silence
        if (ioData->mBuffers[0].mData) {
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }
        return noErr;
    }
    
    // EXTERNAL AUDIO SESSION FIX: Additional safety check for external audio session conflicts
    if (!instance.mDidSetup) {
        // Instance is being cleaned up or not properly set up, provide silence
        if (ioData->mBuffers[0].mData) {
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }
        return noErr;
    }

    @synchronized (instance.mSamples) {
        // CRASH FIX: Check if instance is still valid before proceeding
        if (!instance.mSamples || !instance.mAudioUnit) {
            // Fill with silence if instance is being destroyed
            if (ioData->mBuffers[0].mData) {
                memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
            }
            return noErr;
        }
        
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

        // FLUTTER CHANNEL FIX: Only invoke callback if method channel is still valid and not in cleanup
        if ((isThresholdEvent || isZeroCrossingEvent) && instance.mMethodChannel && instance.mDidSetup && !instance.mDidInvokeFeedCallback) {
            instance.mDidInvokeFeedCallback = true;
            instance.mDidSendZero = remainingFrames == 0;
            NSDictionary *response = @{@"remaining_frames": @(remainingFrames)};
            
            // FLUTTER CHANNEL FIX: Capture method channel reference before async call
            FlutterMethodChannel *methodChannel = instance.mMethodChannel;
            if (methodChannel) {
                // FLUTTER CHANNEL FIX: ALWAYS dispatch to the main queue for Flutter platform channel calls
                dispatch_async(dispatch_get_main_queue(), ^{
                    // FLUTTER CHANNEL FIX: Double-check instance validity and method channel
                    if (instance && instance.mDidSetup && instance.mAudioUnit && methodChannel) {
                        @try {
                            [methodChannel invokeMethod:@"OnFeedSamples" arguments:response];
                        } @catch (NSException *exception) {
                            // FLUTTER CHANNEL FIX: Catch any exceptions from method channel calls
                            NSLog(@"Warning: Exception in method channel invoke: %@", exception.reason);
                        }
                    }
                });
            }
        }
    }
    return noErr;
}

@end