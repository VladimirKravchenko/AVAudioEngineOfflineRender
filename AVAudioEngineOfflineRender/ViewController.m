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
@property(strong, nonatomic) AVAudioEngine *engine;
@property(strong, nonatomic) AVAudioPlayerNode *playerNode;
@property(nonatomic, strong) AVAudioMixerNode *mixer;
@property(nonatomic, strong) AVAudioFile *file;
@property(nonatomic, copy) NSString *resultPath;
@property (weak, nonatomic) IBOutlet UIButton *playButton;
@property(nonatomic, strong) AVAudioPlayer *audioPlayer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self configureAudioEngine];
    NSError *error;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error)
        NSLog(@"%@", error);
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    if (error)
        NSLog(@"%@", error);
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
    NSError *error;
    if (![self.engine startAndReturnError:&error])
        NSLog(@"Can't start engine: %@", error);
    else
        [self scheduleFileToPlay];
}

- (void)scheduleFileToPlay {
    NSError *error;
    NSURL *fileURL = [[NSBundle mainBundle] URLForResource:@"jubel" withExtension:@"m4a"];
    self.file = [[AVAudioFile alloc] initForReading:fileURL error:&error];
    if (self.file)
        [self.playerNode scheduleFile:self.file atTime:nil completionHandler:nil];
    else
        NSLog(@"Can't read file: %@", error);
}

#pragma mark - IBAction

- (IBAction)playButtonPressed:(id)sender {
    if (!self.audioPlayer) {
        NSURL *url = [NSURL fileURLWithPath:self.resultPath];
        NSError *error;
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
        if (error)
            NSLog(@"Can't init audio player: %@", error);
    }
    if ([self.audioPlayer isPlaying]) {
        [self.playButton setTitle:@"Play" forState:UIControlStateNormal];
        [self.audioPlayer stop];
    }
    else {
        [self.playButton setTitle:@"Stop" forState:UIControlStateNormal];
        [self.audioPlayer play];
    }
}

- (IBAction)renderButtonPressed:(id)sender {
    [sender setHidden:YES];
    [self.playerNode play];
    [self.engine pause];
    NSString *path = [self renderAudioAndWriteToFile];
    if (path) {
        self.resultPath = path;
        [self.playButton setHidden:NO];
    }
}

#pragma mark - Offline rendering

- (NSString *)renderAudioAndWriteToFile {
    AVAudioOutputNode *outputNode = self.engine.outputNode;
    AudioStreamBasicDescription const *audioDescription = [outputNode outputFormatForBus:0].streamDescription;
    NSString *path = [self filePath];
    ExtAudioFileRef audioFile = [self createAndSetupExtAudioFileWithASBD:audioDescription andFilePath:path];
    if (!audioFile)
        return nil;
    AVURLAsset *asset = [AVURLAsset assetWithURL:self.file.url];
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    NSUInteger lengthInFrames = (NSUInteger) (duration * audioDescription->mSampleRate);
    const NSUInteger kBufferLength = 3756;
    AudioBufferList *bufferList = AEAllocateAndInitAudioBufferList(*audioDescription, kBufferLength);
    AudioTimeStamp timeStamp;
    memset (&timeStamp, 0, sizeof(timeStamp));
    timeStamp.mFlags = kAudioTimeStampSampleTimeValid;
    OSStatus status = noErr;
    for (NSUInteger i = kBufferLength; i < lengthInFrames; i += kBufferLength) {
        status = [self renderToBufferList:bufferList writeToFile:audioFile bufferLength:kBufferLength timeStamp:&timeStamp];
        if (status != noErr)
            break;
    }
    if (status == noErr && timeStamp.mSampleTime < lengthInFrames) {
        NSUInteger restBufferLength = (NSUInteger) (lengthInFrames - timeStamp.mSampleTime);
        AudioBufferList *restBufferList = AEAllocateAndInitAudioBufferList(*audioDescription, restBufferLength);
        status = [self renderToBufferList:restBufferList writeToFile:audioFile bufferLength:restBufferLength timeStamp:&timeStamp];
        AEFreeAudioBufferList(restBufferList);
    }
    SInt64 fileLengthInFrames;
    UInt32 size = sizeof(SInt64);
    ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &size, &fileLengthInFrames);
    AEFreeAudioBufferList(bufferList);
    ExtAudioFileDispose(audioFile);
    if (status != noErr)
        [self showAlertWithTitle:@"Error" message:@"See logs for details"];
    else {
        NSLog(@"Finished writing to file at path: %@", path);
        [self showAlertWithTitle:@"Success!" message:@"Now you can play a result file"];
    }
    return path;
}

- (NSString *)filePath {
    NSArray *documentsFolders =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *fileName = [NSString stringWithFormat:@"%@.m4a", [[NSUUID UUID] UUIDString]];
    NSString *path = [documentsFolders[0] stringByAppendingPathComponent:fileName];
    return path;
}

- (ExtAudioFileRef)createAndSetupExtAudioFileWithASBD:(AudioStreamBasicDescription const *)audioDescription
                                          andFilePath:(NSString *)path {
    AudioStreamBasicDescription destinationFormat;
    memset(&destinationFormat, 0, sizeof(destinationFormat));
    destinationFormat.mChannelsPerFrame = audioDescription->mChannelsPerFrame;
    destinationFormat.mSampleRate = audioDescription->mSampleRate;
    destinationFormat.mFormatID = kAudioFormatMPEG4AAC;
    ExtAudioFileRef audioFile;
    OSStatus status = ExtAudioFileCreateWithURL(
            (__bridge CFURLRef) [NSURL fileURLWithPath:path],
            kAudioFileM4AType,
            &destinationFormat,
            NULL,
            kAudioFileFlags_EraseFile,
            &audioFile
    );
    if (status != noErr) {
        NSLog(@"Can not create ext audio file");
        return nil;
    }
    UInt32 codecManufacturer = kAppleSoftwareAudioCodecManufacturer;
    status = ExtAudioFileSetProperty(
            audioFile, kExtAudioFileProperty_CodecManufacturer, sizeof(UInt32), &codecManufacturer
    );
    status = ExtAudioFileSetProperty(
            audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), audioDescription
    );
    status = ExtAudioFileWriteAsync(audioFile, 0, NULL);
    if (status != noErr) {
        NSLog(@"Can not setup ext audio file");
        return nil;
    }
    return audioFile;
}

- (OSStatus)renderToBufferList:(AudioBufferList *)bufferList
                   writeToFile:(ExtAudioFileRef)audioFile
                  bufferLength:(NSUInteger)bufferLength
                     timeStamp:(AudioTimeStamp *)timeStamp {
    [self clearBufferList:bufferList];
    AudioUnit outputUnit = self.engine.outputNode.audioUnit;
    OSStatus status = AudioUnitRender(outputUnit, 0, timeStamp, 0, bufferLength, bufferList);
    if (status != noErr) {
        NSLog(@"Can not render audio unit");
        return status;
    }
    timeStamp->mSampleTime += bufferLength;
    status = ExtAudioFileWrite(audioFile, bufferLength, bufferList);
    if (status != noErr)
        NSLog(@"Can not write audio to file");
    return status;
}

- (void)clearBufferList:(AudioBufferList *)bufferList {
    for (int bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; bufferIndex++) {
        memset(bufferList->mBuffers[bufferIndex].mData, 0, bufferList->mBuffers[bufferIndex].mDataByteSize);
    }
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    [[[UIAlertView alloc] initWithTitle:title
                                message:message
                               delegate:nil
                      cancelButtonTitle:@"Ok"
                      otherButtonTitles:nil] show];
}

AudioBufferList *AEAllocateAndInitAudioBufferList(AudioStreamBasicDescription audioFormat, int frameCount) {
    int numberOfBuffers = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? audioFormat.mChannelsPerFrame : 1;
    int channelsPerBuffer = audioFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 1 : audioFormat.mChannelsPerFrame;
    int bytesPerBuffer = audioFormat.mBytesPerFrame * frameCount;
    AudioBufferList *audio = malloc(sizeof(AudioBufferList) + (numberOfBuffers - 1) * sizeof(AudioBuffer));
    if (!audio) {
        return NULL;
    }
    audio->mNumberBuffers = numberOfBuffers;
    for (int i = 0; i < numberOfBuffers; i++) {
        if (bytesPerBuffer > 0) {
            audio->mBuffers[i].mData = calloc(bytesPerBuffer, 1);
            if (!audio->mBuffers[i].mData) {
                for (int j = 0; j < i; j++) free(audio->mBuffers[j].mData);
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

void AEFreeAudioBufferList(AudioBufferList *bufferList) {
    for (int i = 0; i < bufferList->mNumberBuffers; i++) {
        if (bufferList->mBuffers[i].mData) free(bufferList->mBuffers[i].mData);
    }
    free(bufferList);
}

@end
