// SPDX-License-Identifier: GPL-3.0-only
// Native libmpv client. Control, demux and rendering never wait on each other.
#import "HGMPVPlayer.h"
#import <Mpv/client.h>
#import <Mpv/render.h>
#import <Mpv/render_gl.h>
#import <Mpv/stream_cb.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/EAGL.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>
#import <dlfcn.h>
#import <math.h>

typedef struct { void *source; int64_t offset; } HGStream;
static int64_t readStream(void *cookie,char *buffer,uint64_t count) {
    HGStream *s = cookie;
    @autoreleasepool {
        id<HGMPVSource> source = (__bridge id)s->source;
        NSData *data = [source readAtOffset:s->offset count:(NSUInteger)MIN(count,512 * 1024)];
        if (!data) return -1;
        memcpy(buffer,data.bytes,data.length); s->offset += data.length;
        return (int64_t)data.length;
    }
}
static int64_t seekStream(void *cookie,int64_t offset) {
    HGStream *s = cookie;
    id<HGMPVSource> source = (__bridge id)s->source;
    if (offset < 0 || offset > source.length) return MPV_ERROR_GENERIC;
    s->offset = offset; return offset;
}
static int64_t sizeStream(void *cookie) { return [(__bridge id<HGMPVSource>)((HGStream *)cookie)->source length]; }
static void cancelStream(void *cookie) { [(__bridge id<HGMPVSource>)((HGStream *)cookie)->source cancel]; }
static void closeStream(void *cookie) {
    HGStream *s = cookie;
    CFBridgingRelease(s->source); free(s);
}
static int openStream(void *context,char *uri,mpv_stream_cb_info *info) {
    HGStream *s = calloc(1,sizeof(HGStream));
    if (!s) return MPV_ERROR_NOMEM;
    s->source = (__bridge_retained void *)(__bridge id)context;
    *info = (mpv_stream_cb_info){.cookie=s,.read_fn=readStream,.seek_fn=seekStream,
        .size_fn=sizeStream,.close_fn=closeStream,.cancel_fn=cancelStream};
    return 0;
}
static void *getGL(void *ctx,const char *name) { return dlsym(RTLD_DEFAULT,name); }

@interface HGMPVPlayer () {
    id<HGMPVSource> _source;
    mpv_handle *_mpv;
    mpv_render_context *_renderer;
    dispatch_queue_t _controlQueue, _renderQueue;
    dispatch_source_t _timer;
    CADisplayLink *_displayLink;
    EAGLContext *_gl;
    GLuint _fbo,_rbo;
    GLint _width,_height;
    CGSize _targetSize;
    BOOL _resize, _opened, _closed;
    atomic_bool _stopping, _renderQueued, _needsFrame;
    atomic_uint_fast64_t _frames;
    double _startPosition,_speed;
    NSString *_failure;
    BOOL _loaded,_ended;
}
@end

// Display link must not retain the player, otherwise leaving the page leaks it.
@interface HGDisplayTarget : NSObject
@property(nonatomic,weak) HGMPVPlayer *player;
- (void)tick:(CADisplayLink *)link;
@end

@implementation HGMPVPlayer
+ (Class)layerClass {
#if TARGET_OS_SIMULATOR
    return CALayer.class;
#else
    return CAEAGLLayer.class;
#endif
}
- (instancetype)initWithSource:(id<HGMPVSource>)source {
    if ((self = [super initWithFrame:CGRectZero])) {
        _source = source; _speed = 1;
        atomic_init(&_stopping,false); atomic_init(&_renderQueued,false);
        atomic_init(&_needsFrame,true); atomic_init(&_frames,0);
        _controlQueue = dispatch_queue_create("com.hongguotv.mpv.control",DISPATCH_QUEUE_SERIAL);
        _renderQueue = dispatch_queue_create("com.hongguotv.mpv.render",DISPATCH_QUEUE_SERIAL);
        self.backgroundColor = UIColor.blackColor;
        self.contentScaleFactor = UIScreen.mainScreen.scale;
#if !TARGET_OS_SIMULATOR
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking:@NO,kEAGLDrawablePropertyColorFormat:kEAGLColorFormatRGBA8};
#endif
        HGDisplayTarget *target = [HGDisplayTarget new]; target.player = self;
        _displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
        _displayLink.preferredFramesPerSecond = 60;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = CGSizeMake(MAX(2,self.bounds.size.width * self.contentScaleFactor),MAX(2,self.bounds.size.height * self.contentScaleFactor));
    dispatch_async(_renderQueue,^{ self->_targetSize = size; self->_resize = YES; atomic_store(&self->_needsFrame,true); });
}
- (void)fail:(NSString *)message { _failure = message; [self publish]; }
- (BOOL)option:(const char *)name value:(const char *)value {
    int result = mpv_set_option_string(_mpv,name,value);
    if (result < 0) { [self fail:[NSString stringWithFormat:@"mpv %s: %s",name,mpv_error_string(result)]]; return NO; }
    return YES;
}
- (void)openAt:(double)position speed:(double)speed {
    if (_opened || _closed) return;
    _opened = YES; _startPosition = position; _speed = speed;
    dispatch_async(_controlQueue,^{
        if (atomic_load(&self->_stopping)) return;
        self->_mpv = mpv_create();
        if (!self->_mpv) { [self fail:@"无法创建 libmpv"]; return; }
        const char *options[][2] = {{"vo","libmpv"},{"hwdec","auto"},{"video-sync","display-resample"},
            {"audio-pitch-correction","yes"},{"cache","yes"},{"demuxer-max-bytes","33554432"},
            {"demuxer-max-back-bytes","8388608"},{"idle","yes"},{"keep-open","yes"},
            {"terminal","no"},{"input-default-bindings","no"},{"osc","no"},{"osd-level","0"},
            {"stop-playback-on-init-failure","yes"}};
        for (NSUInteger i=0;i<sizeof(options)/sizeof(options[0]);i++) {
            if (![self option:options[i][0] value:options[i][1]]) return;
        }
        int result = mpv_initialize(self->_mpv);
        if (result < 0) { [self fail:[NSString stringWithUTF8String:mpv_error_string(result)]]; return; }
        result = mpv_stream_cb_add_ro(self->_mpv,"hongguo",(__bridge void *)self->_source,openStream);
        if (result < 0) { [self fail:@"无法注册本机解密数据流"]; return; }
        dispatch_async(self->_renderQueue,^{ [self createRenderer]; });
    });
}
static void updateRender(void *ctx) { [(__bridge HGMPVPlayer *)ctx markFrame]; }
- (void)markFrame { atomic_store(&_needsFrame,true); }
- (void)createRenderer {
    if (atomic_load(&_stopping)) return;
    int result;
#if TARGET_OS_SIMULATOR
    mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_SW},{0}};
    result = mpv_render_context_create(&_renderer,_mpv,params);
#else
    _gl = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_gl || ![EAGLContext setCurrent:_gl]) { [self rendererFailed:@"OpenGL ES 初始化失败"]; return; }
    mpv_opengl_init_params glInit = {.get_proc_address=getGL};
    mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&glInit},{0}};
    result = mpv_render_context_create(&_renderer,_mpv,params);
    [EAGLContext setCurrent:nil];
#endif
    if (result < 0) { [self rendererFailed:[NSString stringWithUTF8String:mpv_error_string(result)]]; return; }
    mpv_render_context_set_update_callback(_renderer,updateRender,(__bridge void *)self);
    dispatch_async(_controlQueue,^{
        if (atomic_load(&self->_stopping)) return;
        [self speedOnControl:self->_speed];
        NSString *options = [NSString stringWithFormat:@"start=%.3f",MAX(0,self->_startPosition)];
        const char *args[] = {"loadfile","hongguo://episode","replace","-1",options.UTF8String,NULL};
        int result = mpv_command(self->_mpv,args);
        if (result < 0) { [self fail:[NSString stringWithUTF8String:mpv_error_string(result)]]; return; }
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self->_controlQueue);
        dispatch_source_set_timer(self->_timer,DISPATCH_TIME_NOW,250*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
        __weak HGMPVPlayer *weakSelf = self;
        dispatch_source_set_event_handler(self->_timer,^{ [weakSelf drain]; });
        dispatch_resume(self->_timer);
    });
}
- (void)rendererFailed:(NSString *)error { dispatch_async(_controlQueue,^{ [self fail:error]; }); }
- (void)tick:(CADisplayLink *)link {
    if (atomic_load(&_stopping) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (atomic_exchange(&_renderQueued,true)) return;
    dispatch_async(_renderQueue,^{
        @autoreleasepool { [self drawFrame]; }
        atomic_store(&self->_renderQueued,false);
    });
}
- (void)drawFrame {
    if (!_renderer || atomic_load(&_stopping)) return;
#if !TARGET_OS_SIMULATOR
    [EAGLContext setCurrent:_gl];
#endif
    BOOL changed = atomic_exchange(&_needsFrame,false);
    uint64_t flags = changed ? mpv_render_context_update(_renderer) : 0;
    if (!(flags & MPV_RENDER_UPDATE_FRAME) && !_resize) {
#if !TARGET_OS_SIMULATOR
        [EAGLContext setCurrent:nil];
#endif
        return;
    }
#if TARGET_OS_SIMULATOR
    // Like media_kit, use a bounded software surface in Simulator only.
    int size[2] = {640,360}; size_t stride = 640*4;
    void *pixels = NULL;
    if (posix_memalign(&pixels,64,stride*360) != 0) return;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_SW_SIZE,size},{MPV_RENDER_PARAM_SW_FORMAT,"rgb0"},
        {MPV_RENDER_PARAM_SW_STRIDE,&stride},{MPV_RENDER_PARAM_SW_POINTER,pixels},{0}};
    int result = mpv_render_context_render(_renderer,params);
    if (result >= 0) {
        CFDataRef data = CFDataCreate(kCFAllocatorDefault,pixels,stride*360);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(640,360,8,32,stride,color,kCGImageAlphaNoneSkipLast|kCGBitmapByteOrder32Big,provider,NULL,false,kCGRenderingIntentDefault);
        dispatch_async(dispatch_get_main_queue(),^{ if (!atomic_load(&self->_stopping)) self.layer.contents = (__bridge id)image; CGImageRelease(image); });
        CGColorSpaceRelease(color); CGDataProviderRelease(provider); CFRelease(data);
    }
    free(pixels);
#else
    if (_resize || !_fbo) {
        if (_fbo) glDeleteFramebuffers(1,&_fbo);
        if (_rbo) glDeleteRenderbuffers(1,&_rbo);
        glGenFramebuffers(1,&_fbo); glGenRenderbuffers(1,&_rbo);
        glBindFramebuffer(GL_FRAMEBUFFER,_fbo); glBindRenderbuffer(GL_RENDERBUFFER,_rbo);
        [_gl renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_WIDTH,&_width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_HEIGHT,&_height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,_rbo);
    }
    glBindFramebuffer(GL_FRAMEBUFFER,_fbo);
    if (_width < 1 || _height < 1 || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        [EAGLContext setCurrent:nil]; return;
    }
    mpv_opengl_fbo fbo = {.fbo=(int)_fbo,.w=_width,.h=_height}; int flip = 1;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO,&fbo},{MPV_RENDER_PARAM_FLIP_Y,&flip},{0}};
    int result = mpv_render_context_render(_renderer,params);
    glBindRenderbuffer(GL_RENDERBUFFER,_rbo);
    [_gl presentRenderbuffer:GL_RENDERBUFFER];
#endif
    _resize = NO;
    if (result >= 0) {
        if (flags & MPV_RENDER_UPDATE_FRAME) atomic_fetch_add(&_frames,1);
        mpv_render_context_report_swap(_renderer);
    }
#if !TARGET_OS_SIMULATOR
    [EAGLContext setCurrent:nil];
#endif
}
- (double)number:(const char *)name {
    double value = 0; mpv_get_property(_mpv,name,MPV_FORMAT_DOUBLE,&value); return isfinite(value) ? value : 0;
}
- (BOOL)flag:(const char *)name {
    int value = 0; mpv_get_property(_mpv,name,MPV_FORMAT_FLAG,&value); return value != 0;
}
- (NSString *)text:(const char *)name {
    char *value = mpv_get_property_string(_mpv,name);
    if (!value) return @"";
    NSString *text = [NSString stringWithUTF8String:value] ?: @""; mpv_free(value); return text;
}
- (void)publish {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    if (_mpv && _loaded) {
        state[@"position"] = @([self number:"time-pos"]); state[@"duration"] = @([self number:"duration"]);
        state[@"paused"] = @([self flag:"pause"]); state[@"buffering"] = @([self flag:"paused-for-cache"]);
        state[@"speed"] = @([self number:"speed"]); state[@"hwdec"] = [self text:"hwdec-current"];
        state[@"dropped"] = @([self number:"frame-drop-count"]); state[@"decoderDropped"] = @([self number:"decoder-frame-drop-count"]);
        state[@"avsync"] = @([self number:"avsync"]); state[@"cache"] = @([self number:"demuxer-cache-duration"]);
        state[@"audio"] = [self text:"audio-codec-name"]; state[@"pitchCorrection"] = @([self flag:"audio-pitch-correction"]);
        state[@"audioOutput"] = [self text:"current-ao"]; state[@"video"] = [self text:"video-codec"];
    }
    state[@"loaded"] = @(_loaded); state[@"ended"] = @(_ended);
    state[@"frames"] = @(atomic_load(&_frames));
    if (_failure) state[@"error"] = _failure;
    dispatch_async(dispatch_get_main_queue(),^{ if (!atomic_load(&self->_stopping) && self.onUpdate) self.onUpdate(state); });
}
- (void)drain {
    if (!_mpv || atomic_load(&_stopping)) return;
    while (true) {
        mpv_event *event = mpv_wait_event(_mpv,0);
        if (!event || event->event_id == MPV_EVENT_NONE) break;
        if (event->event_id == MPV_EVENT_FILE_LOADED) _loaded = YES;
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR) _failure = [NSString stringWithFormat:@"mpv: %s",mpv_error_string(end->error)];
            if (end->reason == MPV_END_FILE_REASON_EOF) _ended = YES;
        }
    }
    if (_loaded && [self flag:"eof-reached"]) _ended = YES;
    [self publish];
}
- (void)speedOnControl:(double)speed {
    _speed = speed;
    double cache = 8 * MAX(1,speed);
    int result = mpv_set_property(_mpv,"speed",MPV_FORMAT_DOUBLE,&speed);
    mpv_set_property(_mpv,"cache-secs",MPV_FORMAT_DOUBLE,&cache);
    if (result < 0) [self fail:[NSString stringWithUTF8String:mpv_error_string(result)]];
}
- (void)setSpeed:(double)speed {
    dispatch_async(_controlQueue,^{ if (self->_mpv && !atomic_load(&self->_stopping)) [self speedOnControl:speed]; });
}
- (void)setPaused:(BOOL)paused {
    dispatch_async(_controlQueue,^{
        if (!self->_mpv || atomic_load(&self->_stopping)) return;
        int value = paused; mpv_set_property(self->_mpv,"pause",MPV_FORMAT_FLAG,&value);
        [self publish];
    });
}
- (void)seekTo:(double)position {
    dispatch_async(_controlQueue,^{
        if (!self->_mpv || atomic_load(&self->_stopping)) return;
        self->_ended = NO;
        NSString *time = [NSString stringWithFormat:@"%.3f",MAX(0,position)];
        const char *args[] = {"seek",time.UTF8String,"absolute+exact",NULL};
        int result = mpv_command(self->_mpv,args);
        if (result < 0) [self fail:[NSString stringWithUTF8String:mpv_error_string(result)]];
    });
}
- (void)shutdown {
    if (_closed) return;
    _closed = YES; atomic_store(&_stopping,true);
    [_displayLink invalidate]; _displayLink = nil; self.onUpdate = nil;
    [_source cancel];
    // Drain initialization/commands first, free renderer on its queue, then
    // terminate on control queue. No synchronous cross-queue waits.
    dispatch_async(_controlQueue,^{
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        dispatch_async(self->_renderQueue,^{
#if !TARGET_OS_SIMULATOR
            [EAGLContext setCurrent:self->_gl];
#endif
            if (self->_renderer) {
                mpv_render_context_set_update_callback(self->_renderer,NULL,NULL);
                mpv_render_context_free(self->_renderer); self->_renderer = NULL;
            }
#if !TARGET_OS_SIMULATOR
            if (self->_fbo) glDeleteFramebuffers(1,&self->_fbo);
            if (self->_rbo) glDeleteRenderbuffers(1,&self->_rbo);
            [EAGLContext setCurrent:nil]; self->_gl = nil;
#endif
            dispatch_async(self->_controlQueue,^{ if (self->_mpv) { mpv_terminate_destroy(self->_mpv); self->_mpv = NULL; } });
        });
    });
}
@end

@implementation HGDisplayTarget
- (void)tick:(CADisplayLink *)link { [self.player tick:link]; }
@end
