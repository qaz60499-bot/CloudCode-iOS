/*
 * V141: isolated, deliberately narrow provider for Apple AVFAudio globals.
 * Same names and V137 host-observed string content. No AVAudioApplication
 * class export, no mic APIs, no simulation of input-mute notifications.
 */
#import <Foundation/Foundation.h>
NSNotificationName const AVAudioApplicationInputMuteStateChangeNotification =
    @"AVAudioApplicationInputMuteStateChangeNotification";
#ifndef V141_OMIT_SECOND
NSString *const AVAudioApplicationMuteStateKey =
    @"AVAudioApplicationMuteStateKey";
#endif
