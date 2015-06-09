//
//  ViewController.m
//  AVAudioEngineOfflineRender
//
//  Created by Vladimir Kravchenko on 6/9/15.
//  Copyright (c) 2015 Vladimir S. Kravchenko. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>

@interface ViewController ()
@property (strong, nonatomic) AVAudioEngine *engine;
@property (strong, nonatomic) AVAudioPlayerNode *playerNode;
@property(nonatomic, strong) AVAudioMixerNode *mixer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self configureAudioEngine];
}

#pragma mark - Audio setup

- (void)configureAudioEngine {
    self.engine = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    [self.engine attachNode:self.playerNode];
    AVAudioUnitDistortion *distortionEffect = [[AVAudioUnitDistortion alloc] init];
    [self.engine attachNode:distortionEffect];
    [self.engine connect:self.playerNode to:distortionEffect format:[distortionEffect outputFormatForBus:0]];
    self.mixer = [self.engine mainMixerNode];
    [self.engine connect:distortionEffect to:self.mixer format:[self.mixer outputFormatForBus:0]];
    [distortionEffect loadFactoryPreset:AVAudioUnitDistortionPresetDrumsBitBrush];
    NSError* error;
    if (![self.engine startAndReturnError:&error])
        NSLog(@"Can't start engine: %@", error);
    else
        [self scheduleFIleToPlay];
}

- (void)scheduleFIleToPlay {
    NSError* error;
    NSURL *fileURL = [[NSBundle mainBundle] URLForResource:@"jubel" withExtension:@"m4a"];
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:fileURL error:&error];
    if (file)
        [self.playerNode scheduleFile:file atTime:nil completionHandler:nil];
    else
        NSLog(@"Can't read file: %@", error);
}

#pragma mark - IBAction

- (IBAction)renderButtonPressed:(id)sender {
    [self.playerNode play];
    [self.engine pause];
    [self renderAudioAndWriteToFile];
}

#pragma mark - Offline rendering

- (void)renderAudioAndWriteToFile {
    AVAudioEngine *audioEngine = self.engine;
    AVAudioOutputNode *outputNode = audioEngine.outputNode;
    AudioUnit outputUnit = audioEngine.outputNode.audioUnit;
    AudioStreamBasicDescription const *audioDescription = [outputNode outputFormatForBus:0].streamDescription;
    double sampleRate = audioDescription->mSampleRate;
    NSTimeInterval duration = 40; // your audio duration
    NSUInteger lengthInFrames = (UInt32) (duration * sampleRate);
    const int kBufferLength = 4096;
    AudioBufferList *bufferList = AEAllocateAndInitAudioBufferList(*audioDescription, kBufferLength);
    AudioTimeStamp timeStamp;
    memset (&timeStamp, 0, sizeof(timeStamp));
    timeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    NSArray *documentsFolders =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *fileName = [NSString stringWithFormat:@"%@.m4a", [[NSUUID UUID] UUIDString]];
    NSString *path = [documentsFolders[0] stringByAppendingPathComponent:fileName];
    AudioStreamBasicDescription destinationFormat;
    memset(&destinationFormat, 0, sizeof(destinationFormat));
    destinationFormat.mChannelsPerFrame = audioDescription->mChannelsPerFrame;
    destinationFormat.mSampleRate = audioDescription->mSampleRate;
    destinationFormat.mFormatID = kAudioFormatMPEG4AAC;
    ExtAudioFileRef audioFile;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
            kAudioFileM4AType,
            &destinationFormat,
            NULL,
            kAudioFileFlags_EraseFile,
            &audioFile
    );
    if (status != noErr) {
        NSLog(@"Can not create audio file writer");
        return;
    }
    UInt32 codecManufacturer = kAppleSoftwareAudioCodecManufacturer;
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_CodecManufacturer, sizeof(UInt32), &codecManufacturer);
    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), audioDescription);
    status = ExtAudioFileWriteAsync(audioFile, 0, NULL);
    if (status != noErr) {
        NSLog(@"Can not setup audio file writer");
        return;
    }
    for (NSUInteger i = 0; i < lengthInFrames; i += kBufferLength) {
        for ( int bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; bufferIndex++) {
            memset(bufferList->mBuffers[bufferIndex].mData, 0, bufferList->mBuffers[bufferIndex].mDataByteSize);
        }
        status = AudioUnitRender(outputUnit, 0, &timeStamp, 0, kBufferLength, bufferList);
        if (status != noErr) {
            NSLog(@"Can not render audio unit");
            return;
        }
        timeStamp.mSampleTime += kBufferLength;
        status = ExtAudioFileWrite(audioFile, kBufferLength, bufferList);
        if (status != noErr) {
            NSLog(@"Can not write audio to file");
            return;
        }
    }
    ExtAudioFileDispose(audioFile);
    AEFreeAudioBufferList(bufferList);
    NSLog(@"Finished writing to file at path: %@", path);
}

AudioBufferList *AEAllocateAndInitAudioBufferList(AudioStreamBasicDescription audioFormat, int frameCount) {
    int numberOfBuffers = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioFormat.mChannelsPerFrame : 1;
    int channelsPerBuffer = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioFormat.mChannelsPerFrame;
    int bytesPerBuffer = audioFormat.mBytesPerFrame * frameCount;
    AudioBufferList *audio = malloc(sizeof(AudioBufferList) + (numberOfBuffers-1)*sizeof(AudioBuffer));
    if ( !audio ) {
        return NULL;
    }
    audio->mNumberBuffers = numberOfBuffers;
    for ( int i=0; i<numberOfBuffers; i++ ) {
        if ( bytesPerBuffer > 0 ) {
            audio->mBuffers[i].mData = calloc(bytesPerBuffer, 1);
            if ( !audio->mBuffers[i].mData ) {
                for ( int j=0; j<i; j++ ) free(audio->mBuffers[j].mData);
                free(audio);
                return NULL;
            }
        } else {
            audio->mBuffers[i].mData = NULL;
        }
        audio->mBuffers[i].mDataByteSize = bytesPerBuffer;
        audio->mBuffers[i].mNumberChannels = channelsPerBuffer;
    }
    return audio;
}

void AEFreeAudioBufferList(AudioBufferList *bufferList ) {
    for ( int i=0; i<bufferList->mNumberBuffers; i++ ) {
        if ( bufferList->mBuffers[i].mData ) free(bufferList->mBuffers[i].mData);
    }
    free(bufferList);
}

@end
