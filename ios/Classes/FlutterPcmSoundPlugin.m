#import "FlutterPcmSoundPlugin.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define kOutputBus 0
#define NAMESPACE @"flutter_pcm_sound"

@interface FlutterPcmSoundPlugin ()
@property(nonatomic) FlutterMethodChannel *mMethodChannel;
@property(nonatomic) AudioComponentInstance mAudioUnit;
@property(nonatomic) NSMutableData *mSamples;
@property(nonatomic) int mNumChannels;
@property(nonatomic) int mFeedThreshold;
@property(nonatomic) bool mDidInvokeFeedCallback;
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
    instance.mSamples = [NSMutableData new];
    instance.mFeedThreshold = 8000;
    
    // Listen for system audio interruptions (e.g., phone calls).
    [[NSNotificationCenter defaultCenter] addObserver:instance
                                             selector:@selector(handleInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
    
    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([@"setup" isEqualToString:call.method]) {
        if (_mAudioUnit != nil) { [self cleanup]; }
        
        NSDictionary *args = (NSDictionary*)call.arguments;
        self.mNumChannels = [args[@"num_channels"] intValue];
        self.mAllowBackgroundAudio = [args[@"ios_allow_background_audio"] boolValue];
        
        // 1. Configure and activate the audio session. The plugin now owns its session.
        [self setupAudioSession];
        
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
        FlutterStandardTypedData *buffer = call.arguments[@"buffer"];
        @synchronized (self.mSamples) {
            [self.mSamples appendData:buffer.data];
        }
        self.mDidInvokeFeedCallback = false;
        result(@YES);
        
    } else if ([@"start" isEqualToString:call.method]) {
        if (self.mAudioUnit != nil && !self._isPlaying) {
            // If the audio unit was stopped by an interruption, restart it.
            if (self.mIsInterrupted) {
                AudioOutputUnitStart(self.mAudioUnit);
                self.mIsInterrupted = NO;
            }
            self._isPlaying = YES;
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
        
    } else if ([@"release" isEqualToString:call.method]) {
        [self cleanup];
        result(@YES);
        
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// A dedicated method to handle the audio session setup.
- (void)setupAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategory category = self.mAllowBackgroundAudio ? AVAudioSessionCategoryPlayback : AVAudioSessionCategorySoloAmbient;
    [session setCategory:category error:nil];
    [session setActive:YES error:nil];
}

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
            // The system suggests we can resume. Reactivate our session and AudioUnit.
            [self setupAudioSession];
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
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
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