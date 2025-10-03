#import "FlutterPcmSoundPlugin.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define kOutputBus 0
#define NAMESPACE @"flutter_pcm_sound"

typedef NS_ENUM(NSUInteger, LogLevel) {
    none = 0,
    error = 1,
    standard = 2,
    verbose = 3,
};

@interface FlutterPcmSoundPlugin ()
@property(nonatomic) FlutterMethodChannel *mMethodChannel;
@property(nonatomic) LogLevel mLogLevel;
@property(nonatomic) AudioComponentInstance mAudioUnit;
@property(nonatomic) NSMutableData *mSamples;
@property(nonatomic) int mNumChannels;
@property(nonatomic) int mFeedThreshold;
@property(nonatomic) bool mDidInvokeFeedCallback;
@property(nonatomic) bool mDidSetup;
@property(nonatomic) BOOL _isPlaying;
@property(nonatomic) BOOL mAllowBackgroundAudio;
// A flag to know if the AudioUnit was stopped by a system interruption.
@property(nonatomic) BOOL mIsInterrupted;
@end

@implementation FlutterPcmSoundPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:NAMESPACE @"/methods"
                                                                    binaryMessenger:[registrar messenger]];
    FlutterPcmSoundPlugin *instance = [[FlutterPcmSoundPlugin alloc] init];
    instance.mMethodChannel = methodChannel;
    instance.mLogLevel = standard;
    instance.mSamples = [NSMutableData new];
    instance.mFeedThreshold = 8000;
    instance.mDidSetup = false;
    
    // Listen for system audio interruptions (e.g., phone calls).
    [[NSNotificationCenter defaultCenter] addObserver:instance
                                             selector:@selector(handleInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
    
    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"setLogLevel" isEqualToString:call.method]) {
        NSDictionary *args = (NSDictionary*)call.arguments;
        NSNumber *logLevelNumber = args[@"log_level"];
        self.mLogLevel = (LogLevel)[logLevelNumber integerValue];
        result(@YES);
        
    } else if ([@"setup" isEqualToString:call.method]) {
        if (_mAudioUnit != nil) { [self cleanup]; }
        
        NSDictionary *args = (NSDictionary*)call.arguments;
        self.mNumChannels = [args[@"num_channels"] intValue];
        self.mAllowBackgroundAudio = [args[@"ios_allow_background_audio"] boolValue];
        
        // Audio session is managed externally by the app
        
        // 2. Set up the AudioUnit (same as before).
        AudioComponentDescription desc = {0};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_RemoteIO;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        
        AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
        AudioComponentInstanceNew(inputComponent, &_mAudioUnit);
        
        AudioStreamBasicDescription audioFormat = {0};
        audioFormat.mSampleRate = [args[@"sample_rate"] intValue];
        audioFormat.mFormatID = kAudioFormatLinearPCM;
        audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        audioFormat.mFramesPerPacket = 1;
        audioFormat.mChannelsPerFrame = self.mNumChannels;
        audioFormat.mBitsPerChannel = 16;
        audioFormat.mBytesPerFrame = self.mNumChannels * 2;
        audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
        
        AudioUnitSetProperty(_mAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &audioFormat, sizeof(audioFormat));
        
        AURenderCallbackStruct callbackStruct = {0};
        callbackStruct.inputProc = RenderCallback;
        callbackStruct.inputProcRefCon = (__bridge void *)(self);
        AudioUnitSetProperty(_mAudioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, kOutputBus, &callbackStruct, sizeof(callbackStruct));
        
        AudioUnitInitialize(_mAudioUnit);
        AudioOutputUnitStart(_mAudioUnit);
        
        self._isPlaying = NO;
        self.mIsInterrupted = NO;
        result(@YES);
        
    } else if ([@"feed" isEqualToString:call.method]) {
        // Setup check
        if (self.mDidSetup == false) {
            result([FlutterError errorWithCode:@"Setup" message:@"must call setup first" details:nil]);
            return;
        }
        
        FlutterStandardTypedData *buffer = call.arguments[@"buffer"];
        @synchronized (self.mSamples) {
            [self.mSamples appendData:buffer.data];
        }
        self.mDidInvokeFeedCallback = false;
        
        // Try to start AudioUnit if not already playing, handle error 561015905
        if (!self._isPlaying) {
            OSStatus status = AudioOutputUnitStart(self.mAudioUnit);
            if (status != noErr) {
                // Error 561015905 occurs when trying to start AudioUnit in background state
                if (status == 561015905) {
                    // This is a transient error when app is not fully active
                    // Don't surface this error, just log it and continue
                    NSLog(@"AudioOutputUnitStart failed with transient error 561015905 in feed() (app not fully active)");
                    result(@YES);
                    return;
                } else {
                    // For other errors, surface them
                    NSString* message = [NSString stringWithFormat:@"AudioOutputUnitStart failed in feed(). OSStatus: %d", (int)status];
                    result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                    return;
                }
            }
            self._isPlaying = YES;
        }
        
        result(@YES);
        
    } else if ([@"start" isEqualToString:call.method]) {
        if (self.mAudioUnit != nil && !self._isPlaying) {
            // If the audio unit was stopped by an interruption, restart it.
            if (self.mIsInterrupted) {
                AudioOutputUnitStart(self.mAudioUnit);
                self.mIsInterrupted = NO;
            }
            self._isPlaying = YES;
            
            // Try to start AudioUnit, handle error 561015905 specifically
            OSStatus status = AudioOutputUnitStart(self.mAudioUnit);
            if (status != noErr) {
                // Error 561015905 occurs when trying to start AudioUnit in background state
                if (status == 561015905) {
                    // This is a transient error when app is not fully active
                    // Don't surface this error, just log it and continue
                    NSLog(@"AudioOutputUnitStart failed with transient error 561015905 (app not fully active)");
                    result(@YES);
                    return;
                } else {
                    // For other errors, surface them
                    NSString* message = [NSString stringWithFormat:@"AudioOutputUnitStart failed. OSStatus: %d", (int)status];
                    result([FlutterError errorWithCode:@"AudioUnitError" message:message details:nil]);
                    return;
                }
            }
        }
        result(@YES);
        
    } else if ([@"stop" isEqualToString:call.method]) {
        if (self.mAudioUnit != nil && self._isPlaying) {
            self._isPlaying = NO;
            @synchronized (self.mSamples) {
                [self.mSamples setLength:0];
            }
        }
        result(@YES);
        
    } else if ([@"setFeedThreshold" isEqualToString:call.method]) {
        NSDictionary *args = (NSDictionary*)call.arguments;
        NSNumber *feedThreshold = args[@"feed_threshold"];
        self.mFeedThreshold = [feedThreshold intValue];
        result(@YES);
        
    } else if ([@"release" isEqualToString:call.method]) {
        [self cleanup];
        result(@YES);
        
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// Audio session setup removed - handled externally by the app

// The core of the stability fix: handle system interruptions gracefully.
- (void)handleInterruption:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    AVAudioSessionInterruptionType type = [userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    
    if (type == AVAudioSessionInterruptionTypeBegan) {
        // The system has interrupted our audio. Stop the AudioUnit to be safe.
        if (self.mAudioUnit) {
            AudioOutputUnitStop(self.mAudioUnit);
            self.mIsInterrupted = YES;
        }
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        // The interruption has ended.
        AVAudioSessionInterruptionOptions options = [userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if (options == AVAudioSessionInterruptionOptionShouldResume) {
            // The system suggests we can resume. Restart AudioUnit.
            // Audio session reactivation is handled externally by the app.
            if (self.mAudioUnit) {
                AudioUnitInitialize(self.mAudioUnit);
                AudioOutputUnitStart(self.mAudioUnit);
                self.mIsInterrupted = NO;
            }
        }
    }
}

- (void)cleanup {
    if (_mAudioUnit != nil) {
        AudioOutputUnitStop(_mAudioUnit);
        AudioUnitUninitialize(_mAudioUnit);
        AudioComponentInstanceDispose(_mAudioUnit);
        _mAudioUnit = nil;
        self._isPlaying = NO;
        // Audio session deactivation handled externally by the app
    }
    @synchronized (self.mSamples) {
        [self.mSamples setLength:0];
    }
}

// A much cleaner RenderCallback, free of defensive checks.
static OSStatus RenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    FlutterPcmSoundPlugin *instance = (__bridge FlutterPcmSoundPlugin *)(inRefCon);
    
    @synchronized (instance.mSamples) {
        if (instance._isPlaying && [instance.mSamples length] > 0) {
            NSUInteger bytesToCopy = MIN(ioData->mBuffers[0].mDataByteSize, [instance.mSamples length]);
            memcpy(ioData->mBuffers[0].mData, [instance.mSamples bytes], bytesToCopy);
            [instance.mSamples replaceBytesInRange:NSMakeRange(0, bytesToCopy) withBytes:NULL length:0];
            
            if (bytesToCopy < ioData->mBuffers[0].mDataByteSize) {
                memset(ioData->mBuffers[0].mData + bytesToCopy, 0, ioData->mBuffers[0].mDataByteSize - bytesToCopy);
            }
        } else {
            memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        }

        NSUInteger remainingFrames = [instance.mSamples length] / (instance.mNumChannels * sizeof(short));
        if (remainingFrames <= instance.mFeedThreshold && !instance.mDidInvokeFeedCallback) {
            instance.mDidInvokeFeedCallback = true;
            dispatch_async(dispatch_get_main_queue(), ^{
                [instance.mMethodChannel invokeMethod:@"OnFeedSamples" arguments:@{@"remaining_frames": @(remainingFrames)}];
            });
        }
    }
    return noErr;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end