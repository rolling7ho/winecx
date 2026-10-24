/*
 * Mac graphics driver hooks used by D3DMetal (part of the Apple Game Porting Toolkit)
 *
 * Copyright 2025 Brendan Shanks for CodeWeavers, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */

#if defined(__x86_64__)

#include "config.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <MetalFX/MetalFX.h>
#include <dlfcn.h>
#include <pthread.h>

#include "macdrv_cocoa.h"
#import "cocoa_app.h"
#import "cocoa_event.h"
#import "cocoa_window.h"
#import "d3dmetal_objc.h"

#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"


/* MetalFX upscaling of a swapchain smaller than its window (the "MetalFXUpscale"
 * option).  A game that is not DPI aware renders at the 96 DPI size, half the
 * Retina panel's pixels on each axis, and Core Animation stretched its drawable
 * up with a plain filter.  With the option on, the layer's drawables are the
 * window's full pixel size; the game draws into a texture of the size it asked
 * for, handed out in a stand-in drawable, and when it presents, MetalFX's
 * spatial scaler is encoded into the same command buffer, upscaling into the
 * real drawable just before it is shown.  The real drawable is only taken at
 * that point, so this adds no queueing of its own.
 */

static Class spatial_scaler_descriptor_class(void)
{
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX", RTLD_LAZY | RTLD_LOCAL))
            cls = NSClassFromString(@"MTLFXSpatialScalerDescriptor");
    });
    return cls;
}

@interface WineUpscaleDrawable : NSObject <CAMetalDrawable>
{
    WineMetalLayer* _layer;
    id<MTLTexture> _texture;
    id<MTLFXSpatialScaler> _scaler;
    NSUInteger _drawableID;
    id<CAMetalDrawable> _drawable;
    NSMutableArray* _presentedHandlers;
    id<MTLEvent> _renderedEvent;
    uint64_t _renderedValue;
}
    - (instancetype) initWithLayer:(WineMetalLayer*)layer texture:(id<MTLTexture>)texture
                            scaler:(id<MTLFXSpatialScaler>)scaler drawableID:(NSUInteger)drawableID;
    - (id<CAMetalDrawable>) upscaleInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
    - (void) makeResidentForQueue:(id)queue;
    - (void) signalRenderedOnQueue:(id)queue;
@end

@interface WineMetalLayer ()
    - (id<CAMetalDrawable>) realNextDrawable;
    - (id<MTLCommandQueue>) fallbackQueue;
    - (void) addUpscaleResidencyToQueue:(id)queue;
    - (id<MTLEvent>) renderedEvent:(uint64_t*)value;
@end

@implementation WineUpscaleDrawable

    - (instancetype) initWithLayer:(WineMetalLayer*)layer texture:(id<MTLTexture>)texture
                            scaler:(id<MTLFXSpatialScaler>)scaler drawableID:(NSUInteger)drawableID
    {
        self = [super init];
        if (self)
        {
            _layer = [layer retain];
            _texture = [texture retain];
            _scaler = [scaler retain];
            _drawableID = drawableID;
        }
        return self;
    }

    - (void) dealloc
    {
        [_layer release];
        [_texture release];
        [_scaler release];
        [_drawable release];
        [_presentedHandlers release];
        [_renderedEvent release];
        [super dealloc];
    }

    - (id<MTLTexture>) texture { return _texture; }
    - (CAMetalLayer*) layer { return _layer; }
    - (NSUInteger) drawableID { return _drawableID; }

    - (CFTimeInterval) presentedTime
    {
        @synchronized(self) { return _drawable ? _drawable.presentedTime : 0; }
    }

    /* Handlers wait for the real drawable, and are told this one was presented. */
    - (void) addPresentedHandler:(MTLDrawablePresentedHandler)block
    {
        @synchronized(self)
        {
            if (!_drawable)
            {
                if (!_presentedHandlers) _presentedHandlers = [[NSMutableArray alloc] init];
                [_presentedHandlers addObject:[[block copy] autorelease]];
                return;
            }
        }
        [_drawable addPresentedHandler:^(id<MTLDrawable> drawable) { block(self); }];
    }

    /* The layer's real drawable, taken the first time it is needed. */
    - (id<CAMetalDrawable>) realDrawable
    {
        id<CAMetalDrawable> drawable;
        NSArray* handlers;

        @synchronized(self)
        {
            if (_drawable) return _drawable;
        }
        if (!(drawable = [_layer realNextDrawable])) return nil;
        @synchronized(self)
        {
            if (_drawable) return _drawable;
            _drawable = [drawable retain];
            handlers = [_presentedHandlers autorelease];
            _presentedHandlers = nil;
        }
        for (MTLDrawablePresentedHandler block in handlers)
            [drawable addPresentedHandler:^(id<MTLDrawable> real) { block(self); }];
        return drawable;
    }

    /* Anything else a drawable is asked goes to the real one. */
    - (id) forwardingTargetForSelector:(SEL)sel
    {
        static BOOL logged;
        if (!logged)
        {
            logged = YES;
            NSLog(@"winemac: MetalFX stand-in drawable forwarding %@", NSStringFromSelector(sel));
        }
        return [self realDrawable];
    }

    /* A Metal 4 queue only reaches resources in its residency sets. */
    - (void) makeResidentForQueue:(id)queue
    {
        [_layer addUpscaleResidencyToQueue:queue];
    }

    /* A Metal 4 queue's frame is done with the stand-in once the queue gets
     * past this point; the upscale, on another queue, waits for it. */
    - (void) signalRenderedOnQueue:(id)queue
    {
        uint64_t value;
        id<MTLEvent> event = [_layer renderedEvent:&value];
        if (!event) return;
        [queue signalEvent:event value:value];
        @synchronized(self)
        {
            [_renderedEvent release];
            _renderedEvent = [event retain];
            _renderedValue = value;
        }
    }

    /* Takes the layer's real drawable and encodes the upscale into it. */
    - (id<CAMetalDrawable>) upscaleInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
    {
        id<CAMetalDrawable> drawable = [self realDrawable];
        id<MTLTexture> output = drawable.texture;
        if (!drawable) return nil;
        if (output.width == _scaler.outputWidth && output.height == _scaler.outputHeight)
        {
            _scaler.colorTexture = _texture;
            _scaler.outputTexture = output;
            _scaler.inputContentWidth = _texture.width;
            _scaler.inputContentHeight = _texture.height;
            [_scaler encodeToCommandBuffer:commandBuffer];
        }
        return drawable;
    }

    /* Presenting the drawable itself, as D3DMetal does with a Metal 4 queue:
     * the upscale goes in a command buffer of the layer's own, which waits for
     * the game's queue to signal it is done with the frame. */
    - (void) presentWithCommandBuffer:(void (^)(id<MTLCommandBuffer>, id<CAMetalDrawable>))present
    {
        id<MTLCommandBuffer> commandBuffer = [[_layer fallbackQueue] commandBuffer];
        id<CAMetalDrawable> drawable;
        @synchronized(self)
        {
            if (_renderedEvent) [commandBuffer encodeWaitForEvent:_renderedEvent value:_renderedValue];
        }
        drawable = [self upscaleInCommandBuffer:commandBuffer];
        if (drawable) present(commandBuffer, drawable);
        [commandBuffer commit];
    }

    - (void) present
    {
        [self presentWithCommandBuffer:^(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) { [cb presentDrawable:d]; }];
    }

    - (void) presentAtTime:(CFTimeInterval)time
    {
        [self presentWithCommandBuffer:^(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
            [cb presentDrawable:d atTime:time];
        }];
    }

    - (void) presentAfterMinimumDuration:(CFTimeInterval)duration
    {
        [self presentWithCommandBuffer:^(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d) {
            [cb presentDrawable:d afterMinimumDuration:duration];
        }];
    }

@end


/* The command buffer classes' own present methods are replaced so a stand-in
 * drawable is swapped for the upscaled real one.  Each replacement calls the
 * method it replaced; a subclass's that calls its superclass's reaches that
 * class's replacement with the real drawable already in hand, which it passes
 * on unchanged. */
static id real_drawable_for(id command_buffer, id drawable)
{
    if (![drawable isKindOfClass:[WineUpscaleDrawable class]]) return drawable;
    return [(WineUpscaleDrawable*)drawable upscaleInCommandBuffer:command_buffer];
}

static BOOL class_defines(Class cls, SEL sel)
{
    unsigned int count, i;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;

    for (i = 0; i < count && !found; i++)
        found = method_getName(methods[i]) == sel;
    free(methods);
    return found;
}

static void hook_present(Class cls)
{
    SEL sel = @selector(presentDrawable:);
    if (class_defines(cls, sel))
    {
        Method method = class_getInstanceMethod(cls, sel);
        void (*orig)(id, SEL, id) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(id cb, id drawable) {
            if ((drawable = real_drawable_for(cb, drawable))) orig(cb, sel, drawable);
        }));
    }
}

static void hook_present_with_time(Class cls, SEL sel)
{
    if (class_defines(cls, sel))
    {
        Method method = class_getInstanceMethod(cls, sel);
        void (*orig)(id, SEL, id, CFTimeInterval) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(id cb, id drawable, CFTimeInterval time) {
            if ((drawable = real_drawable_for(cb, drawable))) orig(cb, sel, drawable, time);
        }));
    }
}

/* A Metal 4 queue waits for and signals the drawable itself.  The stand-in
 * needs no waiting (the real drawable is waited for when it is presented),
 * and its signal becomes the event the upscale waits for. */
static void hook_queue(Class cls)
{
    SEL wait = @selector(waitForDrawable:), signal = @selector(signalDrawable:);
    if (class_defines(cls, wait))
    {
        Method method = class_getInstanceMethod(cls, wait);
        void (*orig)(id, SEL, id) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(id queue, id drawable) {
            if ([drawable isKindOfClass:[WineUpscaleDrawable class]])
                [(WineUpscaleDrawable*)drawable makeResidentForQueue:queue];
            else
                orig(queue, wait, drawable);
        }));
    }
    if (class_defines(cls, signal))
    {
        Method method = class_getInstanceMethod(cls, signal);
        void (*orig)(id, SEL, id) = (void *)method_getImplementation(method);
        method_setImplementation(method, imp_implementationWithBlock(^(id queue, id drawable) {
            if ([drawable isKindOfClass:[WineUpscaleDrawable class]])
                [(WineUpscaleDrawable*)drawable signalRenderedOnQueue:queue];
            else
                orig(queue, signal, drawable);
        }));
    }
}

/* Every command buffer class that defines a present method itself: the
 * device's command buffers come in more than one class (plain, unretained
 * references, the validation layer's), and which D3DMetal gets cannot be
 * asked ahead.  Only C runtime calls, so no class is initialized by this. */
static BOOL install_present_hooks(void)
{
    static BOOL installed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int count, i;
        Class *classes = objc_copyClassList(&count);

        for (i = 0; i < count; i++)
        {
            Class cls = classes[i];
            if (strstr(class_getName(cls), "CommandQueue") &&
                (class_defines(cls, @selector(waitForDrawable:)) || class_defines(cls, @selector(signalDrawable:))))
            {
                hook_queue(cls);
                continue;
            }
            if (!strstr(class_getName(cls), "CommandBuffer") || !class_respondsToSelector(cls, @selector(commit)))
                continue;
            if (!class_defines(cls, @selector(presentDrawable:)) &&
                !class_defines(cls, @selector(presentDrawable:atTime:)) &&
                !class_defines(cls, @selector(presentDrawable:afterMinimumDuration:)))
                continue;
            hook_present(cls);
            hook_present_with_time(cls, @selector(presentDrawable:atTime:));
            hook_present_with_time(cls, @selector(presentDrawable:afterMinimumDuration:));
            installed = YES;
        }
        free(classes);
    });
    return installed;
}


@implementation WineMetalLayer
{
    CGSize _gameSize;
    BOOL _upscaling;
    BOOL _framebufferOnly;
    id<MTLFXSpatialScaler> _scaler;
    id<MTLTexture> _textures[4];
    NSUInteger _nextTexture;
    id<MTLCommandQueue> _fallbackQueue;
    id<MTLResidencySet> _residencySet;
    NSMutableSet* _residentQueues;
    id<MTLEvent> _renderedEvent;
    uint64_t _renderedValue;
}

    - (void) dealloc
    {
        unsigned int i;
        [_scaler release];
        for (i = 0; i < 4; i++) [_textures[i] release];
        [_fallbackQueue release];
        [_residencySet release];
        [_residentQueues release];
        [_renderedEvent release];
        [super dealloc];
    }

    /* The window's size in pixels, which the upscale fills. */
    - (CGSize) targetSize
    {
        CGSize size = self.bounds.size;
        CGFloat scale = self.contentsScale;
        return CGSizeMake(floor(size.width * scale + 0.5), floor(size.height * scale + 0.5));
    }

    /* Called with the layer locked. */
    - (void) updateUpscaling
    {
        CGSize target = [self targetSize];
        BOOL upscale = metalfx_upscale && _gameSize.width >= 1 && _gameSize.height >= 1 &&
                       target.width > _gameSize.width * 1.1 && target.height > _gameSize.height * 1.1 &&
                       spatial_scaler_descriptor_class();
        MTLPixelFormat format = self.pixelFormat;
        unsigned int i;

        if (upscale && !(_scaler && _scaler.inputWidth == _gameSize.width && _scaler.inputHeight == _gameSize.height &&
                         _scaler.outputWidth == target.width && _scaler.outputHeight == target.height &&
                         _scaler.colorTextureFormat == format))
        {
            MTLFXSpatialScalerDescriptor *desc = [[spatial_scaler_descriptor_class() alloc] init];
            desc.inputWidth = _gameSize.width;
            desc.inputHeight = _gameSize.height;
            desc.outputWidth = target.width;
            desc.outputHeight = target.height;
            desc.colorTextureFormat = format;
            desc.outputTextureFormat = format;
            desc.colorProcessingMode = format == MTLPixelFormatRGBA16Float ?
                                       MTLFXSpatialScalerColorProcessingModeHDR :
                                       MTLFXSpatialScalerColorProcessingModePerceptual;
            [_scaler release];
            _scaler = [desc newSpatialScalerWithDevice:self.device];
            [desc release];
            for (i = 0; i < 4; i++)
            {
                [_textures[i] release];
                _textures[i] = nil;
            }
            if (_residencySet)
            {
                [_residencySet removeAllAllocations];
                [_residencySet commit];
            }
        }
        upscale = upscale && _scaler && install_present_hooks();

        if (upscale != _upscaling)
            NSLog(@"winemac: MetalFX upscaling %@ (%.0fx%.0f to %.0fx%.0f)", upscale ? @"on" : @"off",
                  _gameSize.width, _gameSize.height, target.width, target.height);
        /* MetalFX writes the drawable from a shader. */
        if (upscale && !_upscaling)
        {
            _framebufferOnly = self.framebufferOnly;
            self.framebufferOnly = NO;
        }
        else if (!upscale && _upscaling)
            self.framebufferOnly = _framebufferOnly;
        _upscaling = upscale;
        [super setDrawableSize:upscale ? target : _gameSize];
    }

    - (void) setDrawableSize:(CGSize)size
    {
        @synchronized(self)
        {
            _gameSize = size;
            [self updateUpscaling];
        }
    }

    - (void) setPixelFormat:(MTLPixelFormat)format
    {
        @synchronized(self)
        {
            [super setPixelFormat:format];
            if (_upscaling) [self updateUpscaling];
        }
    }

    - (id<CAMetalDrawable>) realNextDrawable
    {
        return [super nextDrawable];
    }

    - (id<MTLCommandQueue>) fallbackQueue
    {
        @synchronized(self)
        {
            if (!_fallbackQueue) _fallbackQueue = [self.device newCommandQueue];
            return _fallbackQueue;
        }
    }

    - (void) addUpscaleResidencyToQueue:(id)queue
    {
        @synchronized(self)
        {
            unsigned int i;
            if (!_residencySet)
            {
                MTLResidencySetDescriptor *desc = [[MTLResidencySetDescriptor alloc] init];
                desc.label = @"Wine MetalFX upscale";
                _residencySet = [self.device newResidencySetWithDescriptor:desc error:nil];
                [desc release];
                if (!_residencySet) return;
                for (i = 0; i < 4; i++)
                    if (_textures[i]) [_residencySet addAllocation:_textures[i]];
                [_residencySet commit];
                [_residencySet requestResidency];
                _residentQueues = [[NSMutableSet alloc] init];
            }
            if ([_residentQueues containsObject:[NSValue valueWithNonretainedObject:queue]]) return;
            [_residentQueues addObject:[NSValue valueWithNonretainedObject:queue]];
            [queue addResidencySet:_residencySet];
        }
    }

    - (id<MTLEvent>) renderedEvent:(uint64_t*)value
    {
        @synchronized(self)
        {
            if (!_renderedEvent) _renderedEvent = [self.device newEvent];
            *value = ++_renderedValue;
            return _renderedEvent;
        }
    }

    /* A stand-in drawable at the game's size, or nil when not upscaling. */
    - (id<CAMetalDrawable>) upscaleDrawable
    {
        @synchronized(self)
        {
            id<MTLTexture> texture;

            /* A window resized without a new swapchain size keeps its last
             * upscale, which Core Animation then stretches. */
            if (!_upscaling || self.pixelFormat != _scaler.colorTextureFormat) return nil;

            if (!(texture = _textures[_nextTexture]))
            {
                MTLTextureDescriptor *desc = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:self.pixelFormat
                                                 width:_gameSize.width
                                                height:_gameSize.height
                                             mipmapped:NO];
                desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                             MTLTextureUsageShaderWrite | _scaler.colorTextureUsage;
                desc.storageMode = MTLStorageModePrivate;
                texture = _textures[_nextTexture] = [self.device newTextureWithDescriptor:desc];
                if (_residencySet && texture)
                {
                    [_residencySet addAllocation:texture];
                    [_residencySet commit];
                }
            }
            _nextTexture = (_nextTexture + 1) % 4;
            return [[[WineUpscaleDrawable alloc] initWithLayer:self texture:texture scaler:_scaler
                                                    drawableID:_nextTexture] autorelease];
        }
    }


    /* Extend [CAMetalLayer nextDrawable] so client_surface_present() can be
     * called for the corresponding client_surface.
     */
    - (id<CAMetalDrawable>) nextDrawable
    {
        /* CAMetalLayer's delegate is the WineMetalView that contains it (seems like that's always true
         * for an NSView backing layer).
         * That WineMetalView's parent is the client_surface->cocoa_view WineContentView, it has the
         * client_surface set on it as an associated object.
         */
        if ([self.delegate isKindOfClass:NSClassFromString(@"WineMetalView")])
        {
            NSView* view = (NSView *)self.delegate;
            if ([view.superview isKindOfClass:NSClassFromString(@"WineContentView")] &&
                [view.window    isKindOfClass:NSClassFromString(@"WineWindow")])
            {
                void *client_surface = macdrv_get_view_d3dmetal_client_surface((macdrv_view)view.superview);
                if (client_surface)
                {
                    macdrv_event* event;
                    event = macdrv_create_event(CLIENT_SURFACE_PRESENTED, (WineWindow*)view.window);
                    event->client_surface_presented.client_surface = client_surface;

                    WineEventQueue *queue = [(WineWindow*)view.window queue];
                    [queue postEvent:event];
                    macdrv_release_event(event);
                }
            }
        }

        id<CAMetalDrawable> upscale = [self upscaleDrawable];
        return upscale ? upscale : [super nextDrawable];
    }

@end

#endif
