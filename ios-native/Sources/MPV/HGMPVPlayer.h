// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Called only on mpv's demux thread. Cancellation can arrive on any thread.
@protocol HGMPVSource <NSObject>
@property(nonatomic,readonly) int64_t length;
- (nullable NSData *)readAtOffset:(int64_t)offset count:(NSUInteger)count NS_SWIFT_NAME(read(atOffset:count:));
- (void)cancel;
@end

@interface HGMPVPlayer : UIView
@property(nonatomic,copy,nullable) void (^onUpdate)(NSDictionary<NSString *,id> *state);
- (instancetype)initWithSource:(id<HGMPVSource>)source;
- (void)openAt:(double)position speed:(double)speed NS_SWIFT_NAME(open(at:speed:));
- (void)setSpeed:(double)speed;
- (void)setPaused:(BOOL)paused;
- (void)seekTo:(double)position NS_SWIFT_NAME(seek(to:));
- (void)shutdown;
- (void)shutdownWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(shutdown(completion:));
@end
NS_ASSUME_NONNULL_END
