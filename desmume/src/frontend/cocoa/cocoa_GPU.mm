/*
	Copyright (C) 2013-2025 DeSmuME team

	This file is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 2 of the License, or
	(at your option) any later version.

	This file is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with the this software.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "cocoa_GPU.h"

#include <sys/types.h>
#include <sys/sysctl.h>

#import "cocoa_globals.h"
#include "utilities.h"

#include "../../NDSSystem.h"
#include "../../rasterize.h"

#ifdef MAC_OS_X_VERSION_10_7
	#include "../../OGLRender_3_2.h"
#else
	#include "../../OGLRender.h"
#endif

#ifdef PORT_VERSION_OS_X_APP
	#import "userinterface/CocoaDisplayView.h"
	#import "userinterface/MacOGLDisplayView.h"

	#ifdef ENABLE_APPLE_METAL
		#import "userinterface/MacMetalDisplayView.h"
	#endif
#else
	#import "openemu/OEDisplayView.h"
#endif

#ifdef BOOL
#undef BOOL
#endif

#define GPU_3D_RENDERER_COUNT 3
GPU3DInterface *core3DList[GPU_3D_RENDERER_COUNT+1] = {
	&gpu3DNull,
	&gpu3DRasterize,
	&gpu3Dgl,
	NULL
};

int __hostRendererID = -1;
char __hostRendererString[256] = {0};

@implementation CocoaDSGPU

@dynamic gpuStateFlags;
@dynamic gpuDimensions;
@dynamic gpuScale;
@dynamic gpuColorFormat;

@synthesize openglDeviceMaxMultisamples;

@dynamic layerMainGPU;
@dynamic layerMainBG0;
@dynamic layerMainBG1;
@dynamic layerMainBG2;
@dynamic layerMainBG3;
@dynamic layerMainOBJ;
@dynamic layerSubGPU;
@dynamic layerSubBG0;
@dynamic layerSubBG1;
@dynamic layerSubBG2;
@dynamic layerSubBG3;
@dynamic layerSubOBJ;

@dynamic render3DRenderingEngine;
@dynamic render3DRenderingEngineApplied;
@dynamic render3DRenderingEngineAppliedHostRendererID;
@dynamic render3DRenderingEngineAppliedHostRendererName;
@dynamic render3DHighPrecisionColorInterpolation;
@dynamic render3DEdgeMarking;
@dynamic render3DFog;
@dynamic render3DTextures;
@dynamic render3DThreads;
@dynamic render3DLineHack;
@dynamic render3DMultisampleSize;
@synthesize render3DMultisampleSizeString;
@dynamic render3DTextureDeposterize;
@dynamic render3DTextureSmoothing;
@dynamic render3DTextureScalingFactor;
@dynamic render3DFragmentSamplingHack;
@dynamic openGLEmulateShadowPolygon;
@dynamic openGLEmulateSpecialZeroAlphaBlending;
@dynamic openGLEmulateNDSDepthCalculation;
@dynamic openGLEmulateDepthLEqualPolygonFacing;
@synthesize fetchObject;

- (id)init
{
	self = [super init];
	if (self == nil)
	{
		return self;
	}
	
	_unfairlockGpuState = apple_unfairlock_create();
	
	_gpuScale = 1;
	gpuStateFlags	= GPUSTATE_MAIN_GPU_MASK |
					  GPUSTATE_MAIN_BG0_MASK |
					  GPUSTATE_MAIN_BG1_MASK |
					  GPUSTATE_MAIN_BG2_MASK |
					  GPUSTATE_MAIN_BG3_MASK |
					  GPUSTATE_MAIN_OBJ_MASK |
					  GPUSTATE_SUB_GPU_MASK |
					  GPUSTATE_SUB_BG0_MASK |
					  GPUSTATE_SUB_BG1_MASK |
					  GPUSTATE_SUB_BG2_MASK |
					  GPUSTATE_SUB_BG3_MASK |
					  GPUSTATE_SUB_OBJ_MASK;
	
	isCPUCoreCountAuto = NO;
	_render3DThreadsRequested = 0;
	_render3DThreadCount = 0;
	_needRestoreRender3DLock = NO;
	
	oglrender_init        = &cgl_initOpenGL_StandardAuto;
	oglrender_deinit      = &cgl_deinitOpenGL;
	oglrender_beginOpenGL = &cgl_beginOpenGL;
	oglrender_endOpenGL   = &cgl_endOpenGL;
	oglrender_framebufferDidResizeCallback = &cgl_framebufferDidResizeCallback;
	
#ifdef OGLRENDER_3_2_H
	OGLLoadEntryPoints_3_2_Func = &OGLLoadEntryPoints_3_2;
	OGLCreateRenderer_3_2_Func = &OGLCreateRenderer_3_2;
#endif
	
#ifdef PORT_VERSION_OS_X_APP
	gpuEvent = new MacGPUEventHandlerAsync;
#else
	gpuEvent = new MacGPUEventHandlerAsync_Stub;
#endif
	GPU->SetEventHandler(gpuEvent);
	
	fetchObject = NULL;
	
#ifdef ENABLE_APPLE_METAL
	if (IsOSXVersionSupported(10, 11, 0) && ![[NSUserDefaults standardUserDefaults] boolForKey:@"Debug_DisableMetal"])
	{
		fetchObject = new MacMetalFetchObject;
		
		if (fetchObject->GetClientData() == nil)
		{
			delete fetchObject;
			fetchObject = NULL;
		}
		else
		{
			GPU->SetFramebufferPageCount(METAL_FETCH_BUFFER_COUNT);
			GPU->SetWillPostprocessDisplays(false);
		}
	}
#endif
	
	if (fetchObject == NULL)
	{
#ifdef PORT_VERSION_OS_X_APP
		fetchObject = new MacOGLClientFetchObject;
		GPU->SetWillPostprocessDisplays(false);
#else
		fetchObject = new OE_OGLClientFetchObject;
#endif
		GPU->SetFramebufferPageCount(OPENGL_FETCH_BUFFER_COUNT);
	}
	
	fetchObject->Init();
	gpuEvent->SetFetchObject(fetchObject);
	
	GPU->SetWillAutoResolveToCustomBuffer(false);
	
	openglDeviceMaxMultisamples = 0;
	render3DMultisampleSizeString = @"Off";
	
	bool isTempContextCreated = cgl_initOpenGL_StandardAuto();
	if (isTempContextCreated)
	{
		cgl_beginOpenGL();
		
		GLint maxSamplesOGL = 0;
		
#if defined(GL_MAX_SAMPLES)
		glGetIntegerv(GL_MAX_SAMPLES, &maxSamplesOGL);
#elif defined(GL_MAX_SAMPLES_EXT)
		glGetIntegerv(GL_MAX_SAMPLES_EXT, &maxSamplesOGL);
#endif
		
		openglDeviceMaxMultisamples = maxSamplesOGL;
		
		cgl_endOpenGL();
		cgl_deinitOpenGL();
	}
	
	return self;
}

- (void)dealloc
{
	GPU->SetEventHandler(NULL); // Unassigned our event handler before we delete it.
	
	delete fetchObject;
	delete gpuEvent;
	
	[self setRender3DMultisampleSizeString:nil];
	
	apple_unfairlock_destroy(_unfairlockGpuState);
	
	[super dealloc];
}

- (void) setGpuStateFlags:(UInt32)flags
{
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = flags;
	apple_unfairlock_unlock(_unfairlockGpuState);
	
	[self setLayerMainGPU:((flags & GPUSTATE_MAIN_GPU_MASK) != 0)];
	[self setLayerMainBG0:((flags & GPUSTATE_MAIN_BG0_MASK) != 0)];
	[self setLayerMainBG1:((flags & GPUSTATE_MAIN_BG1_MASK) != 0)];
	[self setLayerMainBG2:((flags & GPUSTATE_MAIN_BG2_MASK) != 0)];
	[self setLayerMainBG3:((flags & GPUSTATE_MAIN_BG3_MASK) != 0)];
	[self setLayerMainOBJ:((flags & GPUSTATE_MAIN_OBJ_MASK) != 0)];
	
	[self setLayerSubGPU:((flags & GPUSTATE_SUB_GPU_MASK) != 0)];
	[self setLayerSubBG0:((flags & GPUSTATE_SUB_BG0_MASK) != 0)];
	[self setLayerSubBG1:((flags & GPUSTATE_SUB_BG1_MASK) != 0)];
	[self setLayerSubBG2:((flags & GPUSTATE_SUB_BG2_MASK) != 0)];
	[self setLayerSubBG3:((flags & GPUSTATE_SUB_BG3_MASK) != 0)];
	[self setLayerSubOBJ:((flags & GPUSTATE_SUB_OBJ_MASK) != 0)];
}

- (UInt32) gpuStateFlags
{
	apple_unfairlock_lock(_unfairlockGpuState);
	const UInt32 flags = gpuStateFlags;
	apple_unfairlock_unlock(_unfairlockGpuState);
	
	return flags;
}

- (void) setGpuDimensions:(NSSize)theDimensions
{
	const size_t w = (size_t)(theDimensions.width + 0.01);
	const size_t h = (size_t)(theDimensions.height + 0.01);
	
	gpuEvent->Render3DLock();
	gpuEvent->FramebufferLock();
	
#ifdef ENABLE_ASYNC_FETCH
	const size_t maxPages = GPU->GetDisplayInfo().framebufferPageCount;
	for (size_t i = 0; i < maxPages; i++)
	{
		semaphore_wait( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
	}
#endif
	
	GPU->SetCustomFramebufferSize(w, h);
	fetchObject->SetFetchBuffers(GPU->GetDisplayInfo());

#ifdef ENABLE_ASYNC_FETCH
	for (size_t i = maxPages - 1; i < maxPages; i--)
	{
		semaphore_signal( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
	}
#endif
	
	gpuEvent->FramebufferUnlock();
	gpuEvent->Render3DUnlock();
	
	if (_needRestoreRender3DLock)
	{
		_needRestoreRender3DLock = NO;
	}
}

- (NSSize) gpuDimensions
{
	gpuEvent->Render3DLock();
	gpuEvent->FramebufferLock();
	const NSSize dimensions = NSMakeSize(GPU->GetCustomFramebufferWidth(), GPU->GetCustomFramebufferHeight());
	gpuEvent->FramebufferUnlock();
	gpuEvent->Render3DUnlock();
	
	return dimensions;
}

- (void) setGpuScale:(NSUInteger)theScale
{
	_gpuScale = (uint8_t)theScale;
	[self setGpuDimensions:NSMakeSize(GPU_FRAMEBUFFER_NATIVE_WIDTH * theScale, GPU_FRAMEBUFFER_NATIVE_HEIGHT * theScale)];
}

- (NSUInteger) gpuScale
{
	return (NSUInteger)_gpuScale;
}

- (void) setGpuColorFormat:(NSUInteger)colorFormat
{
	// First check for a valid color format. Abort if the color format is invalid.
	switch ((NDSColorFormat)colorFormat)
	{
		case NDSColorFormat_BGR555_Rev:
		case NDSColorFormat_BGR666_Rev:
		case NDSColorFormat_BGR888_Rev:
			break;
			
		default:
			return;
	}
	
	// Change the color format.
	gpuEvent->Render3DLock();
	gpuEvent->FramebufferLock();
	
	const NDSDisplayInfo &dispInfo = GPU->GetDisplayInfo();
	
	if (dispInfo.colorFormat != (NDSColorFormat)colorFormat)
	{
#ifdef ENABLE_ASYNC_FETCH
		const size_t maxPages = GPU->GetDisplayInfo().framebufferPageCount;
		for (size_t i = 0; i < maxPages; i++)
		{
			semaphore_wait( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
		}
#endif
		
		GPU->SetColorFormat((NDSColorFormat)colorFormat);
		fetchObject->SetFetchBuffers(GPU->GetDisplayInfo());

#ifdef ENABLE_ASYNC_FETCH
		for (size_t i = maxPages - 1; i < maxPages; i--)
		{
			semaphore_signal( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
		}
#endif
	}
	
	gpuEvent->FramebufferUnlock();
	gpuEvent->Render3DUnlock();
	
	if (_needRestoreRender3DLock)
	{
		_needRestoreRender3DLock = NO;
	}
}

- (NSUInteger) gpuColorFormat
{
	gpuEvent->Render3DLock();
	gpuEvent->FramebufferLock();
	const NSUInteger colorFormat = (NSUInteger)GPU->GetDisplayInfo().colorFormat;
	gpuEvent->FramebufferUnlock();
	gpuEvent->Render3DUnlock();
	
	return colorFormat;
}

- (void) setRender3DRenderingEngine:(NSInteger)rendererID
{
	if (rendererID < CORE3DLIST_NULL)
	{
		rendererID = CORE3DLIST_NULL;
	}
	else if (rendererID >= GPU_3D_RENDERER_COUNT)
	{
		puts("DeSmuME: Invalid 3D renderer chosen; falling back to SoftRasterizer.");
		rendererID = CORE3DLIST_SWRASTERIZE;
	}
	else if (rendererID == CORE3DLIST_OPENGL)
	{
		oglrender_init = &cgl_initOpenGL_StandardAuto;
	}
	
	gpuEvent->ApplyRender3DSettingsLock();
	GPU->Set3DRendererByID((int)rendererID);
	
	if (rendererID == CORE3DLIST_SWRASTERIZE)
	{
		gpuEvent->SetTempThreadCount(_render3DThreadCount);
		GPU->Set3DRendererByID(CORE3DLIST_SWRASTERIZE);
	}
	
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (NSInteger) render3DRenderingEngine
{
	gpuEvent->ApplyRender3DSettingsLock();
	const NSInteger rendererID = (NSInteger)GPU->Get3DRendererID();
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return rendererID;
}

- (NSInteger) render3DRenderingEngineApplied
{
	gpuEvent->ApplyRender3DSettingsLock();
	if ( (gpu3D == NULL) || (CurrentRenderer == NULL) )
	{
		gpuEvent->ApplyRender3DSettingsUnlock();
		return 0;
	}
	
	const NSInteger rendererID = (NSInteger)CurrentRenderer->GetRenderID();
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return rendererID;
}

- (NSInteger) render3DRenderingEngineAppliedHostRendererID
{
	NSInteger hostID = 0;
	
	gpuEvent->ApplyRender3DSettingsLock();
	
	if ( (gpu3D == NULL) || (CurrentRenderer == NULL) )
	{
		gpuEvent->ApplyRender3DSettingsUnlock();
		return hostID;
	}
	
	switch (CurrentRenderer->GetRenderID())
	{
		case RENDERID_OPENGL_AUTO:
		case RENDERID_OPENGL_LEGACY:
		case RENDERID_OPENGL_3_2:
			hostID = (NSInteger)__hostRendererID;
			break;
			
		case RENDERID_NULL:
		case RENDERID_SOFTRASTERIZER:
		default:
			break;
	}
	
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return hostID;
}

- (NSString *) render3DRenderingEngineAppliedHostRendererName
{
	NSString *theString = @"Uninitialized";
	
	gpuEvent->ApplyRender3DSettingsLock();
	
	if ( (gpu3D == NULL) || (CurrentRenderer == NULL) )
	{
		gpuEvent->ApplyRender3DSettingsUnlock();
		return theString;
	}
	
	std::string theName;
	
	switch (CurrentRenderer->GetRenderID())
	{
		case RENDERID_OPENGL_AUTO:
		case RENDERID_OPENGL_LEGACY:
		case RENDERID_OPENGL_3_2:
			theName = std::string((const char *)__hostRendererString);
			break;
			
		case RENDERID_NULL:
		case RENDERID_SOFTRASTERIZER:
		default:
			theName = CurrentRenderer->GetName();
			break;
	}
	
	theString = [NSString stringWithCString:theName.c_str() encoding:NSUTF8StringEncoding];
	
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return theString;
}

- (void) setRender3DHighPrecisionColorInterpolation:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_HighResolutionInterpolateColor = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DHighPrecisionColorInterpolation
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_HighResolutionInterpolateColor ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DEdgeMarking:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_EdgeMark = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DEdgeMarking
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_EdgeMark ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DFog:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_Fog = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DFog
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_Fog ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DTextures:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_Texture = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DTextures
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_Texture ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DThreads:(NSUInteger)numberThreads
{
	_render3DThreadsRequested = (int)numberThreads;
	
	const int numberCores = CommonSettings.num_cores;
	int newThreadCount = numberCores;
	
	if (numberThreads == 0)
	{
		isCPUCoreCountAuto = YES;
		if (numberCores < 2)
		{
			newThreadCount = 1;
		}
		else
		{
			const int reserveCoreCount = numberCores / 12; // For every 12 cores, reserve 1 core for the rest of the system.
			newThreadCount -= reserveCoreCount;
		}
	}
	else
	{
		isCPUCoreCountAuto = NO;
		newThreadCount = (int)numberThreads;
	}
	
	const RendererID renderingEngineID = (RendererID)[self render3DRenderingEngine];
	_render3DThreadCount = newThreadCount;
	
	gpuEvent->ApplyRender3DSettingsLock();
	
	if (renderingEngineID == RENDERID_SOFTRASTERIZER)
	{
		gpuEvent->SetTempThreadCount(newThreadCount);
		GPU->Set3DRendererByID(renderingEngineID);
	}
	
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (NSUInteger) render3DThreads
{
	return (isCPUCoreCountAuto) ? 0 : (NSUInteger)_render3DThreadsRequested;
}

- (void) setRender3DLineHack:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_LineHack = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DLineHack
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_LineHack ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DMultisampleSize:(NSUInteger)msaaSize
{
	gpuEvent->ApplyRender3DSettingsLock();
	
	const NSUInteger currentMSAASize = (NSUInteger)CommonSettings.GFX3D_Renderer_MultisampleSize;
	
	if (currentMSAASize != msaaSize)
	{
		switch (currentMSAASize)
		{
			case 0:
			{
				if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 2;
				}
				break;
			}
				
			case 2:
			{
				if (msaaSize == (currentMSAASize-1))
				{
					msaaSize = 0;
				}
				else if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 4;
				}
				break;
			}
				
			case 4:
			{
				if (msaaSize == (currentMSAASize-1))
				{
					msaaSize = 2;
				}
				else if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 8;
				}
				break;
			}
				
			case 8:
			{
				if (msaaSize == (currentMSAASize-1))
				{
					msaaSize = 4;
				}
				else if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 16;
				}
				break;
			}
				
			case 16:
			{
				if (msaaSize == (currentMSAASize-1))
				{
					msaaSize = 8;
				}
				else if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 32;
				}
				break;
			}
				
			case 32:
			{
				if (msaaSize == (currentMSAASize-1))
				{
					msaaSize = 16;
				}
				else if (msaaSize == (currentMSAASize+1))
				{
					msaaSize = 32;
				}
				break;
			}
		}
		
		if (msaaSize > openglDeviceMaxMultisamples)
		{
			msaaSize = openglDeviceMaxMultisamples;
		}
		
		msaaSize = GetNearestPositivePOT((uint32_t)msaaSize);
		CommonSettings.GFX3D_Renderer_MultisampleSize = (int)msaaSize;
	}
	
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	NSString *newMsaaSizeString = (msaaSize == 0) ? @"Off" : [NSString stringWithFormat:@"%d", (int)msaaSize];
	[self setRender3DMultisampleSizeString:newMsaaSizeString];
}

- (NSUInteger) render3DMultisampleSize
{
	gpuEvent->ApplyRender3DSettingsLock();
	const NSInteger msaaSize = (NSUInteger)CommonSettings.GFX3D_Renderer_MultisampleSize;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return msaaSize;
}

- (void) setRender3DTextureDeposterize:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_Renderer_TextureDeposterize = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DTextureDeposterize
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_Renderer_TextureDeposterize ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DTextureSmoothing:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_Renderer_TextureSmoothing = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DTextureSmoothing
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_Renderer_TextureSmoothing ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setRender3DTextureScalingFactor:(NSUInteger)scalingFactor
{
	int newScalingFactor = (int)scalingFactor;
	
	if (scalingFactor < 1)
	{
		newScalingFactor = 1;
	}
	else if (scalingFactor > 4)
	{
		newScalingFactor = 4;
	}
	
	gpuEvent->ApplyRender3DSettingsLock();
	
	if (newScalingFactor == 3)
	{
		newScalingFactor = (newScalingFactor < CommonSettings.GFX3D_Renderer_TextureScalingFactor) ? 2 : 4;
	}
	
	CommonSettings.GFX3D_Renderer_TextureScalingFactor = newScalingFactor;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (NSUInteger) render3DTextureScalingFactor
{
	gpuEvent->ApplyRender3DSettingsLock();
	const NSUInteger scalingFactor = (NSUInteger)CommonSettings.GFX3D_Renderer_TextureScalingFactor;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return scalingFactor;
}

- (void) setRender3DFragmentSamplingHack:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.GFX3D_TXTHack = state ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) render3DFragmentSamplingHack
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = CommonSettings.GFX3D_TXTHack ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setOpenGLEmulateShadowPolygon:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.OpenGL_Emulation_ShadowPolygon = (state) ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) openGLEmulateShadowPolygon
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = (CommonSettings.OpenGL_Emulation_ShadowPolygon) ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setOpenGLEmulateSpecialZeroAlphaBlending:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.OpenGL_Emulation_SpecialZeroAlphaBlending = (state) ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) openGLEmulateSpecialZeroAlphaBlending
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = (CommonSettings.OpenGL_Emulation_SpecialZeroAlphaBlending) ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setOpenGLEmulateNDSDepthCalculation:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.OpenGL_Emulation_NDSDepthCalculation = (state) ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) openGLEmulateNDSDepthCalculation
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = (CommonSettings.OpenGL_Emulation_NDSDepthCalculation) ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setOpenGLEmulateDepthLEqualPolygonFacing:(BOOL)state
{
	gpuEvent->ApplyRender3DSettingsLock();
	CommonSettings.OpenGL_Emulation_DepthLEqualPolygonFacing = (state) ? true : false;
	gpuEvent->ApplyRender3DSettingsUnlock();
}

- (BOOL) openGLEmulateDepthLEqualPolygonFacing
{
	gpuEvent->ApplyRender3DSettingsLock();
	const BOOL state = (CommonSettings.OpenGL_Emulation_DepthLEqualPolygonFacing) ? YES : NO;
	gpuEvent->ApplyRender3DSettingsUnlock();
	
	return state;
}

- (void) setLayerMainGPU:(BOOL)gpuState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetEnableState((gpuState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (gpuState) ? (gpuStateFlags | GPUSTATE_MAIN_GPU_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_GPU_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainGPU
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL gpuState = GPU->GetEngineMain()->GetEnableState() ? YES : NO;
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return gpuState;
}

- (void) setLayerMainBG0:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetLayerEnableState(GPULayerID_BG0, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_MAIN_BG0_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_BG0_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainBG0
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineMain()->GetLayerEnableState(GPULayerID_BG0);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerMainBG1:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetLayerEnableState(GPULayerID_BG1, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_MAIN_BG1_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_BG1_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainBG1
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineMain()->GetLayerEnableState(GPULayerID_BG1);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerMainBG2:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetLayerEnableState(GPULayerID_BG2, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_MAIN_BG2_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_BG2_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainBG2
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineMain()->GetLayerEnableState(GPULayerID_BG2);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerMainBG3:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetLayerEnableState(GPULayerID_BG3, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_MAIN_BG3_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_BG3_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainBG3
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineMain()->GetLayerEnableState(GPULayerID_BG3);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerMainOBJ:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineMain()->SetLayerEnableState(GPULayerID_OBJ, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_MAIN_OBJ_MASK) : (gpuStateFlags & ~GPUSTATE_MAIN_OBJ_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerMainOBJ
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineMain()->GetLayerEnableState(GPULayerID_OBJ);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerSubGPU:(BOOL)gpuState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetEnableState((gpuState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (gpuState) ? (gpuStateFlags | GPUSTATE_SUB_GPU_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_GPU_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubGPU
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL gpuState = GPU->GetEngineSub()->GetEnableState() ? YES : NO;
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return gpuState;
}

- (void) setLayerSubBG0:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetLayerEnableState(GPULayerID_BG0, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_SUB_BG0_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_BG0_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubBG0
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineSub()->GetLayerEnableState(GPULayerID_BG0);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerSubBG1:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetLayerEnableState(GPULayerID_BG1, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_SUB_BG1_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_BG1_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubBG1
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineSub()->GetLayerEnableState(GPULayerID_BG1);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerSubBG2:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetLayerEnableState(GPULayerID_BG2, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_SUB_BG2_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_BG2_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubBG2
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineSub()->GetLayerEnableState(GPULayerID_BG2);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerSubBG3:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetLayerEnableState(GPULayerID_BG3, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_SUB_BG3_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_BG3_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubBG3
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineSub()->GetLayerEnableState(GPULayerID_BG3);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (void) setLayerSubOBJ:(BOOL)layerState
{
	gpuEvent->ApplyGPUSettingsLock();
	GPU->GetEngineSub()->SetLayerEnableState(GPULayerID_OBJ, (layerState) ? true : false);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	apple_unfairlock_lock(_unfairlockGpuState);
	gpuStateFlags = (layerState) ? (gpuStateFlags | GPUSTATE_SUB_OBJ_MASK) : (gpuStateFlags & ~GPUSTATE_SUB_OBJ_MASK);
	apple_unfairlock_unlock(_unfairlockGpuState);
}

- (BOOL) layerSubOBJ
{
	gpuEvent->ApplyGPUSettingsLock();
	const BOOL layerState = GPU->GetEngineSub()->GetLayerEnableState(GPULayerID_OBJ);
	gpuEvent->ApplyGPUSettingsUnlock();
	
	return layerState;
}

- (BOOL) gpuStateByBit:(const UInt32)stateBit
{
	return ([self gpuStateFlags] & (1 << stateBit)) ? YES : NO;
}

- (void) clearWithColor:(const uint16_t)colorBGRA5551
{
	gpuEvent->FramebufferLock();
	
#ifdef ENABLE_ASYNC_FETCH
	const size_t maxPages = GPU->GetDisplayInfo().framebufferPageCount;
	for (size_t i = 0; i < maxPages; i++)
	{
		semaphore_wait( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
	}
#endif
	
	GPU->ClearWithColor(colorBGRA5551);
	
#ifdef ENABLE_ASYNC_FETCH
	for (size_t i = maxPages - 1; i < maxPages; i--)
	{
		semaphore_signal( ((MacGPUFetchObjectAsync *)fetchObject)->SemaphoreFramebufferPageAtIndex(i) );
	}
#endif
	
	gpuEvent->FramebufferUnlock();
	
#ifdef ENABLE_ASYNC_FETCH
	const u8 bufferIndex = GPU->GetDisplayInfo().bufferIndex;
	((MacGPUFetchObjectAsync *)fetchObject)->SignalFetchAtIndex(bufferIndex, MESSAGE_FETCH_AND_PERFORM_ACTIONS);
#endif
}

- (void) respondToPauseState:(BOOL)isPaused
{
	if (isPaused)
	{
		if (!_needRestoreRender3DLock && gpuEvent->GetRender3DNeedsFinish())
		{
			gpuEvent->Render3DUnlock();
			_needRestoreRender3DLock = YES;
		}
	}
	else
	{
		if (_needRestoreRender3DLock && gpuEvent->GetRender3DNeedsFinish())
		{
			gpuEvent->Render3DLock();
		}
		
		_needRestoreRender3DLock = NO;
	}
}

@end

#ifdef ENABLE_SHARED_FETCH_OBJECT

@implementation MacClientSharedObject

@synthesize GPUFetchObject;

- (id)init
{
	self = [super init];
	if (self == nil)
	{
		return self;
	}
	
	GPUFetchObject = nil;
	
	return self;
}

@end

#pragma mark -

static void* RunFetchThread(void *arg)
{
#if defined(MAC_OS_X_VERSION_10_6) && (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_6)
	if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber10_6)
	{
		pthread_setname_np("Video Fetch");
	}
#endif
	
	MacGPUFetchObjectAsync *asyncFetchObj = (MacGPUFetchObjectAsync *)arg;
	asyncFetchObj->RunFetchLoop();
	
	return NULL;
}

MacGPUFetchObjectAsync::MacGPUFetchObjectAsync()
{
	_threadFetch = NULL;
	_threadMessageID = MESSAGE_NONE;
	_fetchIndex = 0;
	pthread_cond_init(&_condSignalFetch, NULL);
	pthread_mutex_init(&_mutexFetchExecute, NULL);
	
	_id = GPUClientFetchObjectID_GenericAsync;
	
	memset(_name, 0, sizeof(_name));
	strncpy(_name, "Generic Asynchronous Video", sizeof(_name) - 1);
	
	memset(_description, 0, sizeof(_description));
	strncpy(_description, "No description.", sizeof(_description) - 1);
	
	_taskEmulationLoop = 0;
	
	for (size_t i = 0; i < MAX_FRAMEBUFFER_PAGES; i++)
	{
		_semFramebuffer[i] = 0;
		_framebufferState[i] = ClientDisplayBufferState_Idle;
		_unfairlockFramebufferStates[i] = apple_unfairlock_create();
	}
}

MacGPUFetchObjectAsync::~MacGPUFetchObjectAsync()
{
	pthread_cancel(this->_threadFetch);
	pthread_join(this->_threadFetch, NULL);
	this->_threadFetch = NULL;
	
	pthread_cond_destroy(&this->_condSignalFetch);
	pthread_mutex_destroy(&this->_mutexFetchExecute);
}

void MacGPUFetchObjectAsync::Init()
{
	if (CommonSettings.num_cores > 1)
	{
		pthread_attr_t threadAttr;
		pthread_attr_init(&threadAttr);
		pthread_attr_setschedpolicy(&threadAttr, SCHED_RR);
		
		struct sched_param sp;
		memset(&sp, 0, sizeof(struct sched_param));
		sp.sched_priority = 44;
		pthread_attr_setschedparam(&threadAttr, &sp);
		
		pthread_create(&_threadFetch, &threadAttr, &RunFetchThread, this);
		pthread_attr_destroy(&threadAttr);
	}
	else
	{
		pthread_create(&_threadFetch, NULL, &RunFetchThread, this);
	}
}

void MacGPUFetchObjectAsync::SemaphoreFramebufferCreate()
{
	this->_taskEmulationLoop = mach_task_self();
	
	for (size_t i = 0; i < MAX_FRAMEBUFFER_PAGES; i++)
	{
		semaphore_create(this->_taskEmulationLoop, &this->_semFramebuffer[i], SYNC_POLICY_FIFO, 1);
	}
}

void MacGPUFetchObjectAsync::SemaphoreFramebufferDestroy()
{
	for (size_t i = MAX_FRAMEBUFFER_PAGES - 1; i < MAX_FRAMEBUFFER_PAGES; i--)
	{
		if (this->_semFramebuffer[i] != 0)
		{
			semaphore_destroy(this->_taskEmulationLoop, this->_semFramebuffer[i]);
			this->_semFramebuffer[i] = 0;
		}
	}
}

uint8_t MacGPUFetchObjectAsync::SelectBufferIndex(const uint8_t currentIndex, size_t pageCount)
{
	uint8_t selectedIndex = currentIndex;
	bool stillSearching = true;
	
	// First, search for an idle buffer along with its corresponding semaphore.
	if (stillSearching)
	{
		selectedIndex = (selectedIndex + 1) % pageCount;
		for (; selectedIndex != currentIndex; selectedIndex = (selectedIndex + 1) % pageCount)
		{
			if (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Idle)
			{
				stillSearching = false;
				break;
			}
		}
	}
	
	// Next, search for either an idle or a ready buffer along with its corresponding semaphore.
	if (stillSearching)
	{
		selectedIndex = (selectedIndex + 1) % pageCount;
		for (size_t spin = 0; spin < 100ULL * pageCount; selectedIndex = (selectedIndex + 1) % pageCount, spin++)
		{
			if ( (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Idle) ||
				((this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Ready) && (selectedIndex != currentIndex)) )
			{
				stillSearching = false;
				break;
			}
		}
	}
	
	// Since the most available buffers couldn't be taken, we're going to spin for some finite
	// period of time until an idle buffer emerges. If that happens, then force wait on the
	// buffer's corresponding semaphore.
	if (stillSearching)
	{
		selectedIndex = (selectedIndex + 1) % pageCount;
		for (size_t spin = 0; spin < 10000ULL * pageCount; selectedIndex = (selectedIndex + 1) % pageCount, spin++)
		{
			if (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Idle)
			{
				stillSearching = false;
				break;
			}
		}
	}
	
	// In an effort to find something that is likely to be available shortly in the future,
	// search for any idle, ready or reading buffer, and then force wait on its corresponding
	// semaphore.
	if (stillSearching)
	{
		selectedIndex = (selectedIndex + 1) % pageCount;
		for (; selectedIndex != currentIndex; selectedIndex = (selectedIndex + 1) % pageCount)
		{
			if ( (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Idle) ||
				 (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Ready) ||
				 (this->FramebufferStateAtIndex(selectedIndex) == ClientDisplayBufferState_Reading) )
			{
				stillSearching = false;
				break;
			}
		}
	}
	
	return selectedIndex;
}

semaphore_t MacGPUFetchObjectAsync::SemaphoreFramebufferPageAtIndex(const u8 bufferIndex)
{
	assert(bufferIndex < MAX_FRAMEBUFFER_PAGES);
	return this->_semFramebuffer[bufferIndex];
}

ClientDisplayBufferState MacGPUFetchObjectAsync::FramebufferStateAtIndex(uint8_t index)
{
	apple_unfairlock_lock(this->_unfairlockFramebufferStates[index]);
	const ClientDisplayBufferState bufferState = this->_framebufferState[index];
	apple_unfairlock_unlock(this->_unfairlockFramebufferStates[index]);
	
	return bufferState;
}

void MacGPUFetchObjectAsync::SetFramebufferState(ClientDisplayBufferState bufferState, uint8_t index)
{
	apple_unfairlock_lock(this->_unfairlockFramebufferStates[index]);
	this->_framebufferState[index] = bufferState;
	apple_unfairlock_unlock(this->_unfairlockFramebufferStates[index]);
}

void MacGPUFetchObjectAsync::FetchSynchronousAtIndex(uint8_t index)
{
	this->FetchFromBufferIndex(index);
}

void MacGPUFetchObjectAsync::SignalFetchAtIndex(uint8_t index, int32_t messageID)
{
	pthread_mutex_lock(&this->_mutexFetchExecute);
	
	this->_fetchIndex = index;
	this->_threadMessageID = messageID;
	pthread_cond_signal(&this->_condSignalFetch);
	
	pthread_mutex_unlock(&this->_mutexFetchExecute);
}

void MacGPUFetchObjectAsync::RunFetchLoop()
{
	NSAutoreleasePool *tempPool = nil;
	pthread_mutex_lock(&this->_mutexFetchExecute);
	
	do
	{
		tempPool = [[NSAutoreleasePool alloc] init];
		
		while (this->_threadMessageID == MESSAGE_NONE)
		{
			pthread_cond_wait(&this->_condSignalFetch, &this->_mutexFetchExecute);
		}
		
		const uint32_t lastMessageID = this->_threadMessageID;
		this->FetchFromBufferIndex(this->_fetchIndex);
		
		if (lastMessageID == MESSAGE_FETCH_AND_PERFORM_ACTIONS)
		{
			this->DoPostFetchActions();
		}
		
		this->_threadMessageID = MESSAGE_NONE;
		
		[tempPool release];
	} while(true);
}

void MacGPUFetchObjectAsync::DoPostFetchActions()
{
	// Do nothing.
}

#pragma mark -

static void ScreenChangeCallback(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo)
{
	((MacGPUFetchObjectDisplayLink *)observer)->DisplayLinkListUpdate();
}

static CVReturn MacDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                       const CVTimeStamp *inNow,
                                       const CVTimeStamp *inOutputTime,
                                       CVOptionFlags flagsIn,
                                       CVOptionFlags *flagsOut,
                                       void *displayLinkContext)
{
	MacGPUFetchObjectDisplayLink *fetchObj = (MacGPUFetchObjectDisplayLink *)displayLinkContext;
	
	NSAutoreleasePool *tempPool = [[NSAutoreleasePool alloc] init];
	fetchObj->FlushAllViewsOnDisplayLink(displayLink, inNow, inOutputTime);
	[tempPool release];
	
	return kCVReturnSuccess;
}

MacGPUFetchObjectDisplayLink::MacGPUFetchObjectDisplayLink()
{
	_id = GPUClientFetchObjectID_MacDisplayLink;
	
	memset(_name, 0, sizeof(_name));
	strncpy(_name, "macOS Display Link GPU Fetch", sizeof(_name) - 1);
	
	memset(_description, 0, sizeof(_description));
	strncpy(_description, "No description.", sizeof(_description) - 1);
	
	pthread_mutex_init(&_mutexDisplayLinkLists, NULL);
	
	_displayLinksActiveList.clear();
	_displayLinkFlushTimeList.clear();
	DisplayLinkListUpdate();
	
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(),
	                                this,
	                                ScreenChangeCallback,
	                                CFSTR("NSApplicationDidChangeScreenParametersNotification"),
	                                NULL,
	                                CFNotificationSuspensionBehaviorDeliverImmediately);
}

MacGPUFetchObjectDisplayLink::~MacGPUFetchObjectDisplayLink()
{
	CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(),
	                                   this,
	                                   CFSTR("NSApplicationDidChangeScreenParametersNotification"),
	                                   NULL);
	
	pthread_mutex_lock(&this->_mutexDisplayLinkLists);
	
	while (this->_displayLinksActiveList.size() > 0)
	{
		DisplayLinksActiveMap::iterator it = this->_displayLinksActiveList.begin();
		CGDirectDisplayID displayID = it->first;
		CVDisplayLinkRef displayLinkRef = it->second;
		
		if (CVDisplayLinkIsRunning(displayLinkRef))
		{
			CVDisplayLinkStop(displayLinkRef);
		}
		
		CVDisplayLinkRelease(displayLinkRef);
		
		this->_displayLinksActiveList.erase(displayID);
		this->_displayLinkFlushTimeList.erase(displayID);
	}
	
	pthread_mutex_unlock(&this->_mutexDisplayLinkLists);
	pthread_mutex_destroy(&this->_mutexDisplayLinkLists);
}

void MacGPUFetchObjectDisplayLink::DisplayLinkStartUsingID(CGDirectDisplayID displayID)
{
	CVDisplayLinkRef displayLink = NULL;
	
	pthread_mutex_lock(&this->_mutexDisplayLinkLists);
	
	if (this->_displayLinksActiveList.find(displayID) != this->_displayLinksActiveList.end())
	{
		displayLink = this->_displayLinksActiveList[displayID];
	}
	
	if ( (displayLink != NULL) && !CVDisplayLinkIsRunning(displayLink) )
	{
		CVDisplayLinkStart(displayLink);
	}
	
	pthread_mutex_unlock(&this->_mutexDisplayLinkLists);
}

void MacGPUFetchObjectDisplayLink::DisplayLinkListUpdate()
{
	// Set up the display links
	NSArray *screenList = [NSScreen screens];
	std::set<CGDirectDisplayID> screenActiveDisplayIDsList;
	
	pthread_mutex_lock(&this->_mutexDisplayLinkLists);
	
	// Add new CGDirectDisplayIDs for new screens
	for (size_t i = 0; i < [screenList count]; i++)
	{
		NSScreen *screen = [screenList objectAtIndex:i];
		NSDictionary *deviceDescription = [screen deviceDescription];
		NSNumber *idNumber = (NSNumber *)[deviceDescription valueForKey:@"NSScreenNumber"];
		
		CGDirectDisplayID displayID = [idNumber unsignedIntValue];
		bool isDisplayLinkStillActive = (this->_displayLinksActiveList.find(displayID) != this->_displayLinksActiveList.end());
		
		if (!isDisplayLinkStillActive)
		{
			CVDisplayLinkRef newDisplayLink;
			CVDisplayLinkCreateWithCGDisplay(displayID, &newDisplayLink);
			CVDisplayLinkSetOutputCallback(newDisplayLink, &MacDisplayLinkCallback, this);
			
			this->_displayLinksActiveList[displayID] = newDisplayLink;
			this->_displayLinkFlushTimeList[displayID] = 0;
		}
		
		// While we're iterating through NSScreens, save the CGDirectDisplayID to a temporary list for later use.
		screenActiveDisplayIDsList.insert(displayID);
	}
	
	// Remove old CGDirectDisplayIDs for screens that no longer exist
	for (DisplayLinksActiveMap::iterator it = this->_displayLinksActiveList.begin(); it != this->_displayLinksActiveList.end(); )
	{
		CGDirectDisplayID displayID = it->first;
		CVDisplayLinkRef displayLinkRef = it->second;
		
		if (screenActiveDisplayIDsList.find(displayID) == screenActiveDisplayIDsList.end())
		{
			if (CVDisplayLinkIsRunning(displayLinkRef))
			{
				CVDisplayLinkStop(displayLinkRef);
			}
			
			CVDisplayLinkRelease(displayLinkRef);
			
			this->_displayLinksActiveList.erase(displayID);
			this->_displayLinkFlushTimeList.erase(displayID);
			
			if (this->_displayLinksActiveList.empty())
			{
				break;
			}
			else
			{
				it = this->_displayLinksActiveList.begin();
				continue;
			}
		}
		
		++it;
	}
	
	pthread_mutex_unlock(&this->_mutexDisplayLinkLists);
}

void MacGPUFetchObjectDisplayLink::FlushAllViewsOnDisplayLink(CVDisplayLinkRef displayLink, const CVTimeStamp *timeStampNow, const CVTimeStamp *timeStampOutput)
{
	CGDirectDisplayID displayID = CVDisplayLinkGetCurrentCGDisplay(displayLink);
	bool didFlushOccur = false;
	
	std::vector<ClientDisplayViewInterface *> cdvFlushList;
	this->_outputManager->GenerateFlushListForDisplay((int32_t)displayID, cdvFlushList);
	
	const size_t listSize = cdvFlushList.size();
	if (listSize > 0)
	{
		this->FlushMultipleViews(cdvFlushList, (uint64_t)timeStampNow->videoTime, timeStampOutput->hostTime);
		didFlushOccur = true;
	}
	
	if (didFlushOccur)
	{
		// Set the new time limit to 8 seconds after the current time.
		this->_displayLinkFlushTimeList[displayID] = timeStampNow->videoTime + (timeStampNow->videoTimeScale * VIDEO_FLUSH_TIME_LIMIT_OFFSET);
	}
	else if (timeStampNow->videoTime > this->_displayLinkFlushTimeList[displayID])
	{
		CVDisplayLinkStop(displayLink);
	}
}

void MacGPUFetchObjectDisplayLink::DoPostFetchActions()
{
	this->PushVideoDataToAllDisplayViews();
}

#endif // ENABLE_SHARED_FETCH_OBJECT

#pragma mark -

MacGPUEventHandlerAsync::MacGPUEventHandlerAsync()
{
	_fetchObject = nil;
	_render3DNeedsFinish = false;
	_cpuCoreCountRestoreValue = 0;
	
	pthread_mutex_init(&_mutexFrame, NULL);
	pthread_mutex_init(&_mutex3DRender, NULL);
	pthread_mutex_init(&_mutexApplyGPUSettings, NULL);
	pthread_mutex_init(&_mutexApplyRender3DSettings, NULL);
}

MacGPUEventHandlerAsync::~MacGPUEventHandlerAsync()
{
	if (this->_render3DNeedsFinish)
	{
		pthread_mutex_unlock(&this->_mutex3DRender);
	}
	
	pthread_mutex_destroy(&this->_mutexFrame);
	pthread_mutex_destroy(&this->_mutex3DRender);
	pthread_mutex_destroy(&this->_mutexApplyGPUSettings);
	pthread_mutex_destroy(&this->_mutexApplyRender3DSettings);
}

GPUClientFetchObject* MacGPUEventHandlerAsync::GetFetchObject() const
{
	return this->_fetchObject;
}

void MacGPUEventHandlerAsync::SetFetchObject(GPUClientFetchObject *fetchObject)
{
	this->_fetchObject = fetchObject;
}

#ifdef ENABLE_ASYNC_FETCH

void MacGPUEventHandlerAsync::DidFrameBegin(const size_t line, const bool isFrameSkipRequested, const size_t pageCount, u8 &selectedBufferIndexInOut)
{
	MacGPUFetchObjectAsync *asyncFetchObj = (MacGPUFetchObjectAsync *)this->_fetchObject;
	
	this->FramebufferLock();
	
	if (!isFrameSkipRequested)
	{
		if ( (pageCount > 1) && (line == 0) )
		{
			selectedBufferIndexInOut = asyncFetchObj->SelectBufferIndex(selectedBufferIndexInOut, pageCount);
		}
		
		semaphore_wait( asyncFetchObj->SemaphoreFramebufferPageAtIndex(selectedBufferIndexInOut) );
		asyncFetchObj->SetFramebufferState(ClientDisplayBufferState_Writing, selectedBufferIndexInOut);
	}
}

void MacGPUEventHandlerAsync::DidFrameEnd(bool isFrameSkipped, const NDSDisplayInfo &latestDisplayInfo)
{
	MacGPUFetchObjectAsync *asyncFetchObj = (MacGPUFetchObjectAsync *)this->_fetchObject;
	
	if (!isFrameSkipped)
	{
		asyncFetchObj->SetFetchDisplayInfo(latestDisplayInfo);
		asyncFetchObj->SetFramebufferState(ClientDisplayBufferState_Ready, latestDisplayInfo.bufferIndex);
		semaphore_signal( asyncFetchObj->SemaphoreFramebufferPageAtIndex(latestDisplayInfo.bufferIndex) );
	}
	
	this->FramebufferUnlock();
	
	if (!isFrameSkipped)
	{
		asyncFetchObj->SignalFetchAtIndex(latestDisplayInfo.bufferIndex, MESSAGE_FETCH_AND_PERFORM_ACTIONS);
	}
}

#endif // ENABLE_ASYNC_FETCH

void MacGPUEventHandlerAsync::DidRender3DBegin()
{
	this->Render3DLock();
	this->_render3DNeedsFinish = true;
}

void MacGPUEventHandlerAsync::DidRender3DEnd()
{
	this->_render3DNeedsFinish = false;
	this->Render3DUnlock();
}

void MacGPUEventHandlerAsync::DidApplyGPUSettingsBegin()
{
	this->ApplyGPUSettingsLock();
}

void MacGPUEventHandlerAsync::DidApplyGPUSettingsEnd()
{
	this->ApplyGPUSettingsUnlock();
}

void MacGPUEventHandlerAsync::DidApplyRender3DSettingsBegin()
{
	this->ApplyRender3DSettingsLock();
}

void MacGPUEventHandlerAsync::DidApplyRender3DSettingsEnd()
{
	if (this->_cpuCoreCountRestoreValue > 0)
	{
		CommonSettings.num_cores = this->_cpuCoreCountRestoreValue;
	}
	
	this->_cpuCoreCountRestoreValue = 0;
	this->ApplyRender3DSettingsUnlock();
}

void MacGPUEventHandlerAsync::FramebufferLock()
{
	pthread_mutex_lock(&this->_mutexFrame);
}

void MacGPUEventHandlerAsync::FramebufferUnlock()
{
	pthread_mutex_unlock(&this->_mutexFrame);
}

void MacGPUEventHandlerAsync::Render3DLock()
{
	pthread_mutex_lock(&this->_mutex3DRender);
}

void MacGPUEventHandlerAsync::Render3DUnlock()
{
	pthread_mutex_unlock(&this->_mutex3DRender);
}

void MacGPUEventHandlerAsync::ApplyGPUSettingsLock()
{
	pthread_mutex_lock(&this->_mutexApplyGPUSettings);
}

void MacGPUEventHandlerAsync::ApplyGPUSettingsUnlock()
{
	pthread_mutex_unlock(&this->_mutexApplyGPUSettings);
}

void MacGPUEventHandlerAsync::ApplyRender3DSettingsLock()
{
	pthread_mutex_lock(&this->_mutexApplyRender3DSettings);
}

void MacGPUEventHandlerAsync::ApplyRender3DSettingsUnlock()
{
	pthread_mutex_unlock(&this->_mutexApplyRender3DSettings);
}

bool MacGPUEventHandlerAsync::GetRender3DNeedsFinish()
{
	return this->_render3DNeedsFinish;
}

void MacGPUEventHandlerAsync::SetTempThreadCount(int threadCount)
{
	if (threadCount < 1)
	{
		this->_cpuCoreCountRestoreValue = 0;
	}
	else
	{
		this->_cpuCoreCountRestoreValue = CommonSettings.num_cores;
		CommonSettings.num_cores = threadCount;
	}
}

#pragma mark -

#if !defined(MAC_OS_X_VERSION_10_7)
	#define kCGLPFAOpenGLProfile         (CGLPixelFormatAttribute)99
	#define kCGLOGLPVersion_Legacy       0x1000
	#define kCGLOGLPVersion_3_2_Core     0x3200
	#define kCGLOGLPVersion_GL3_Core     0x3200
	#define kCGLRPVideoMemoryMegabytes   (CGLRendererProperty)131
	#define kCGLRPTextureMemoryMegabytes (CGLRendererProperty)132
#endif

#if !defined(MAC_OS_X_VERSION_10_9)
	#define kCGLOGLPVersion_GL4_Core 0x4100
#endif

#if !defined(MAC_OS_X_VERSION_10_13)
	#define kCGLRPRemovable (CGLRendererProperty)142
#endif

CGLContextObj OSXOpenGLRendererContext = NULL;
CGLContextObj OSXOpenGLRendererContextPrev = NULL;
SILENCE_DEPRECATION_MACOS_10_7( CGLPBufferObj OSXOpenGLRendererPBuffer = NULL )

// Struct to hold renderer info
struct HostRendererInfo
{
	int32_t rendererID;      // Renderer ID, used to associate a renderer with a display device or virtual screen
	int32_t accelerated;     // Hardware acceleration flag, 0 = Software only, 1 = Has hardware acceleration
	int32_t displayID;       // Display ID, used to associate a display device with a renderer
	int32_t online;          // Online flag, 0 = No display device associated, 1 = Display device associated
	int32_t removable;       // Removable flag, used to indicate if the renderer is removable (like an eGPU), 0 = Fixed, 1 = Removable
	int32_t virtualScreen;   // Virtual screen index, used to associate a virtual screen with a renderer
	int32_t videoMemoryMB;   // The total amount of VRAM available to this renderer
	int32_t textureMemoryMB; // The amount of VRAM available to this renderer for texture usage
	char vendor[256];        // C-string copy of the host renderer's vendor
	char name[256];          // C-string copy of the host renderer's name
	const void *vendorStr;   // Pointer to host renderer's vendor string (parsing this is implementation dependent)
	const void *nameStr;     // Pointer to host renderer's name string (parsing this is implementation dependent)
};
typedef struct HostRendererInfo HostRendererInfo;

static bool __cgl_initOpenGL(const int requestedProfile)
{
	bool result = false;
	CACHE_ALIGN char ctxString[16] = {0};
	
	if (requestedProfile == kCGLOGLPVersion_GL4_Core)
	{
		strncpy(ctxString, "CGL 4.1", sizeof(ctxString));
	}
	else if (requestedProfile == kCGLOGLPVersion_3_2_Core)
	{
		strncpy(ctxString, "CGL 3.2", sizeof(ctxString));
	}
	else
	{
		strncpy(ctxString, "CGL Legacy", sizeof(ctxString));
	}
	
	if (OSXOpenGLRendererContext != NULL)
	{
		result = true;
		return result;
	}
	
	const bool isHighSierraSupported   = IsOSXVersionSupported(10, 13, 0);
	const bool isMavericksSupported    = (isHighSierraSupported   || IsOSXVersionSupported(10, 9, 0));
	const bool isMountainLionSupported = (isMavericksSupported    || IsOSXVersionSupported(10, 8, 0));
	const bool isLionSupported         = (isMountainLionSupported || IsOSXVersionSupported(10, 7, 0));
	const bool isLeopardSupported      = (isLionSupported         || IsOSXVersionSupported(10, 5, 0));
	
	CGLPixelFormatAttribute attrs[] = {
		kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
		kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
		kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
		kCGLPFAStencilSize, (CGLPixelFormatAttribute)8,
		kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)0,
		kCGLPFAAllowOfflineRenderers,
		kCGLPFAAccelerated,
		kCGLPFANoRecovery,
		(CGLPixelFormatAttribute)0
	};
	
	if (requestedProfile == kCGLOGLPVersion_GL4_Core)
	{
		if (isMavericksSupported)
		{
			attrs[5] = (CGLPixelFormatAttribute)0; // We'll be using FBOs instead of the default framebuffer.
			attrs[7] = (CGLPixelFormatAttribute)0; // We'll be using FBOs instead of the default framebuffer.
			attrs[9] = (CGLPixelFormatAttribute)requestedProfile;
		}
		else
		{
			fprintf(stderr, "%s: Your version of OS X is too old to support 4.1 Core Profile.\n", ctxString);
			return result;
		}
	}
	else if (requestedProfile == kCGLOGLPVersion_3_2_Core)
	{
		// As of 2021/09/03, testing has shown that macOS v10.7's OpenGL 3.2 shader
		// compiler isn't very reliable, and so we're going to require macOS v10.8
		// instead, which at least has a working shader compiler for OpenGL 3.2.
		if (isMountainLionSupported)
		{
			attrs[5] = (CGLPixelFormatAttribute)0; // We'll be using FBOs instead of the default framebuffer.
			attrs[7] = (CGLPixelFormatAttribute)0; // We'll be using FBOs instead of the default framebuffer.
			attrs[9] = (CGLPixelFormatAttribute)requestedProfile;
		}
		else
		{
			fprintf(stderr, "%s: Your version of OS X is too old to support 3.2 Core Profile.\n", ctxString);
			return result;
		}
	}
	else if (isLionSupported)
	{
		attrs[9] = (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy;
	}
	else
	{
		attrs[8]  = (CGLPixelFormatAttribute)kCGLPFAAccelerated;
		attrs[9]  = (CGLPixelFormatAttribute)kCGLPFANoRecovery;
		attrs[11] = (CGLPixelFormatAttribute)0;
		attrs[12] = (CGLPixelFormatAttribute)0;
	}
	
	CGLError error = kCGLNoError;
	CGLPixelFormatObj cglPixFormat = NULL;
	CGLContextObj newContext = NULL;
	GLint virtualScreenCount = 0;
	
	CGLChoosePixelFormat(attrs, &cglPixFormat, &virtualScreenCount);
	if (cglPixFormat == NULL)
	{
		if (requestedProfile == kCGLOGLPVersion_GL4_Core)
		{
			// OpenGL 4.1 Core Profile requires hardware acceleration. Bail if we can't find a renderer that supports both.
			fprintf(stderr, "%s: This system has no HW-accelerated renderers that support 4.1 Core Profile.\n", ctxString);
			return result;
		}
		else if (requestedProfile == kCGLOGLPVersion_3_2_Core)
		{
			// OpenGL 3.2 Core Profile requires hardware acceleration. Bail if we can't find a renderer that supports both.
			fprintf(stderr, "%s: This system has no HW-accelerated renderers that support 3.2 Core Profile.\n", ctxString);
			return result;
		}
		
		// For Legacy OpenGL, we'll allow fallback to the Apple Software Renderer.
		// However, doing this will result in a substantial performance loss.
		if (attrs[8] == kCGLPFAAccelerated)
		{
			attrs[8]  = (CGLPixelFormatAttribute)0;
			attrs[9]  = (CGLPixelFormatAttribute)0;
			attrs[10] = (CGLPixelFormatAttribute)0;
		}
		else
		{
			attrs[10] = (CGLPixelFormatAttribute)0;
			attrs[11] = (CGLPixelFormatAttribute)0;
			attrs[12] = (CGLPixelFormatAttribute)0;
		}
		
		error = CGLChoosePixelFormat(attrs, &cglPixFormat, &virtualScreenCount);
		if (error != kCGLNoError)
		{
			// We shouldn't fail at this point, but we're including this to account for all code paths.
			fprintf(stderr, "%s: Failed to create the pixel format structure: %i\n", ctxString, (int)error);
			return result;
		}
		else
		{
			printf("WARNING: No HW-accelerated renderers were found -- falling back to Apple Software Renderer.\n         This will result in a substantial performance loss.");
		}
	}
	
	// Create the OpenGL context using our pixel format, and then save the default assigned virtual screen.
	error = CGLCreateContext(cglPixFormat, NULL, &newContext);
	CGLReleasePixelFormat(cglPixFormat);
	cglPixFormat = NULL;
	
	if (error != kCGLNoError)
	{
		fprintf(stderr, "%s: Failed to create an OpenGL context: %i\n", ctxString, (int)error);
		return result;
	}
	
	OSXOpenGLRendererContext = newContext;
	GLint defaultVirtualScreen = 0;
	CGLGetVirtualScreen(newContext, &defaultVirtualScreen);
	
	// Retrieve the properties of every renderer available on the system.
	CGLRendererInfoObj cglRendererInfo = NULL;
	GLint rendererCount = 0;
	CGLQueryRendererInfo(0xFFFFFFFF, &cglRendererInfo, &rendererCount);
	
	HostRendererInfo *rendererInfo = (HostRendererInfo *)malloc(sizeof(HostRendererInfo) * rendererCount);
	memset(rendererInfo, 0, sizeof(HostRendererInfo) * rendererCount);
	
	if (isLeopardSupported)
	{
		for (GLint i = 0; i < rendererCount; i++)
		{
			HostRendererInfo &info = rendererInfo[i];
			
			CGLDescribeRenderer(cglRendererInfo, i, kCGLRPOnline, &(info.online));
			CGLDescribeRenderer(cglRendererInfo, i, kCGLRPDisplayMask, &(info.displayID));
			info.displayID = (GLint)CGOpenGLDisplayMaskToDisplayID(info.displayID);
			CGLDescribeRenderer(cglRendererInfo, i, kCGLRPAccelerated, &(info.accelerated));
			CGLDescribeRenderer(cglRendererInfo, i, kCGLRPRendererID,  &(info.rendererID));
			
			if (isLionSupported)
			{
				CGLDescribeRenderer(cglRendererInfo, i, kCGLRPVideoMemoryMegabytes, &(info.videoMemoryMB));
				CGLDescribeRenderer(cglRendererInfo, i, kCGLRPTextureMemoryMegabytes, &(info.textureMemoryMB));
			}
			else
			{
				CGLDescribeRenderer(cglRendererInfo, i, kCGLRPVideoMemory, &(info.videoMemoryMB));
				info.videoMemoryMB = (GLint)(((uint32_t)info.videoMemoryMB + 1) >> 20);
				CGLDescribeRenderer(cglRendererInfo, i, kCGLRPTextureMemory, &(info.textureMemoryMB));
				info.textureMemoryMB = (GLint)(((uint32_t)info.textureMemoryMB + 1) >> 20);
			}
			
			if (isHighSierraSupported)
			{
				CGLDescribeRenderer(cglRendererInfo, i, kCGLRPRemovable, &(info.removable));
			}
		}
	}
	else
	{
		CGLDestroyRendererInfo(cglRendererInfo);
		free(rendererInfo);
		fprintf(stderr, "%s: Failed to retrieve renderer info - requires Mac OS X v10.5 or later.\n", ctxString);
		return result;
	}
	
	CGLDestroyRendererInfo(cglRendererInfo);
	cglRendererInfo = NULL;
	
	// Retrieve the vendor and renderer info from OpenGL.
	cgl_beginOpenGL();
	
	for (GLint i = 0; i < virtualScreenCount; i++)
	{
		CGLSetVirtualScreen(newContext, i);
		GLint r;
		CGLGetParameter(newContext, kCGLCPCurrentRendererID, &r);

		for (int j = 0; j < rendererCount; j++)
		{
			HostRendererInfo &info = rendererInfo[j];
			
			if (r == info.rendererID)
			{
				info.virtualScreen = i;
				
				info.vendorStr = (const char *)glGetString(GL_VENDOR);
				if (info.vendorStr != NULL)
				{
					strncpy(info.vendor, (const char *)info.vendorStr, sizeof(info.vendor));
				}
				else if (info.accelerated == 0)
				{
					strncpy(info.vendor, "Apple Inc.", sizeof(info.vendor));
				}
				else
				{
					strncpy(info.vendor, "UNKNOWN", sizeof(info.vendor));
				}
				
				info.nameStr = (const char *)glGetString(GL_RENDERER);
				if (info.nameStr != NULL)
				{
					strncpy(info.name, (const char *)info.nameStr, sizeof(info.name));
				}
				else if (info.accelerated == 0)
				{
					strncpy(info.name, "Apple Software Renderer", sizeof(info.name));
				}
				else
				{
					strncpy(info.name, "UNKNOWN", sizeof(info.name));
				}
				
			}
		}
	}
	
	cgl_endOpenGL();
	
	// Get the default virtual screen.
	strncpy(__hostRendererString, "UNKNOWN", sizeof(__hostRendererString));
	__hostRendererID = -1;
	
	HostRendererInfo defaultRendererInfo = rendererInfo[0];
	for (int i = 0; i < rendererCount; i++)
	{
		if (defaultVirtualScreen == rendererInfo[i].virtualScreen)
		{
			defaultRendererInfo = rendererInfo[i];
			__hostRendererID = defaultRendererInfo.rendererID;
			strncpy(__hostRendererString, (const char *)defaultRendererInfo.name, sizeof(__hostRendererString));
			
			if ( (defaultRendererInfo.online == 1) && (defaultRendererInfo.vendorStr != NULL) && (defaultRendererInfo.nameStr != NULL) )
			{
				break;
			}
		}
	}
	
	printf("Default OpenGL Renderer: [0x%08X] %s\n", __hostRendererID, __hostRendererString);
	/*
	bool isDefaultRunningIntegratedGPU = false;
	if ( (defaultRendererInfo.online == 1) && (defaultRendererInfo.vendorStr != NULL) && (defaultRendererInfo.nameStr != NULL) )
	{
		const HostRendererInfo &d = defaultRendererInfo;
		isDefaultRunningIntegratedGPU = (strstr(d.name, "GMA 950") != NULL) ||
		                                (strstr(d.name, "GMA X3100") != NULL) ||
		                                (strstr(d.name, "GeForce 9400M") != NULL) ||
		                                (strstr(d.name, "GeForce 320M") != NULL) ||
		                                (strstr(d.name, "HD Graphics") != NULL) ||
		                                (strstr(d.name, "Iris 5100") != NULL) ||
		                                (strstr(d.name, "Iris Plus") != NULL) ||
		                                (strstr(d.name, "Iris Pro") != NULL) ||
		                                (strstr(d.name, "Iris Graphics") != NULL) ||
		                                (strstr(d.name, "UHD Graphics") != NULL);
	}
	*/
#if defined(DEBUG) && (DEBUG == 1)
	// Report information on every renderer.
	if (!isLionSupported)
	{
		printf("WARNING: You are running a macOS version earlier than v10.7.\n         Video Memory and Texture Memory reporting is capped\n         at 2048 MB on older macOS.\n");
	}
	printf("CGL Renderer Count: %i\n", rendererCount);
	printf("  Virtual Screen Count: %i\n\n", virtualScreenCount);
	
	for (int i = 0; i < rendererCount; i++)
	{
		const HostRendererInfo &info = rendererInfo[i];
		
		printf("Renderer Index: %i\n", i);
		printf("Virtual Screen: %i\n", info.virtualScreen);
		printf("Vendor: %s\n", info.vendor);
		printf("Renderer: %s\n", info.name);
		printf("Renderer ID: 0x%08X\n", info.rendererID);
		printf("Accelerated: %s\n", (info.accelerated == 1) ? "YES" : "NO");
		printf("Online: %s\n", (info.online == 1) ? "YES" : "NO");
		
		if (isHighSierraSupported)
		{
			printf("Removable: %s\n", (info.removable == 1) ? "YES" : "NO");
		}
		else
		{
			printf("Removable: UNSUPPORTED, Requires High Sierra\n");
		}
		
		printf("Display ID: 0x%08X\n", info.displayID);
		printf("Video Memory: %i MB\n", info.videoMemoryMB);
		printf("Texture Memory: %i MB\n\n", info.textureMemoryMB);
	}
#endif
	
	// Search for a better virtual screen that will suit our offscreen rendering better.
	//
	// At the moment, we are not supporting removable renderers such as eGPUs. Attempting
	// to support removable renderers would require a lot more code to handle dynamically
	// changing display<-->renderer associations. - rogerman 2025/03/25
	bool wasBetterVirtualScreenFound = false;
	
	char *modelCString = NULL;
	size_t modelStringLen = 0;
	
	sysctlbyname("hw.model", NULL, &modelStringLen, NULL, 0);
	if (modelStringLen > 0)
	{
		modelCString = (char *)malloc(modelStringLen * sizeof(char));
		sysctlbyname("hw.model", modelCString, &modelStringLen, NULL, 0);
	}
	
	for (int i = 0; i < rendererCount; i++)
	{
		const HostRendererInfo &info = rendererInfo[i];
		
		if ( (defaultRendererInfo.vendorStr == NULL) || (defaultRendererInfo.nameStr == NULL) || (info.vendorStr == NULL) || (info.nameStr == NULL) )
		{
			continue;
		}
		
		wasBetterVirtualScreenFound = (info.accelerated == 1) &&
		(    (        (modelCString != NULL) && (strstr((const char *)modelCString, "MacBookPro") != NULL) &&
		         (  ( (strstr(defaultRendererInfo.name, "GeForce 9400M") != NULL) &&
		              (strstr(info.name, "GeForce 9600M GT") != NULL) ) ||
		            ( (strstr(defaultRendererInfo.name, "HD Graphics") != NULL) &&
		             ((strstr(info.name, "GeForce GT 330M") != NULL) ||
		              (strstr(info.name, "Radeon HD 6490M") != NULL) ||
		              (strstr(info.name, "Radeon HD 6750M") != NULL) ||
		              (strstr(info.name, "Radeon HD 6770M") != NULL) ||
		              (strstr(info.name, "GeForce GT 650M") != NULL) ||
		              (strstr(info.name, "Radeon Pro 450") != NULL) ||
		              (strstr(info.name, "Radeon Pro 455") != NULL) ||
		              (strstr(info.name, "Radeon Pro 555") != NULL) ||
		              (strstr(info.name, "Radeon Pro 560") != NULL)) ) ||
		            ( (strstr(defaultRendererInfo.name, "Iris Pro") != NULL) &&
		             ((strstr(info.name, "GeForce GT 750M") != NULL) ||
		              (strstr(info.name, "Radeon R9 M370X") != NULL)) ) ||
		            ( (strstr(defaultRendererInfo.name, "UHD Graphics") != NULL) &&
		             ((strstr(info.name, "Radeon Pro 555X") != NULL) ||
		              (strstr(info.name, "Radeon Pro 560X") != NULL) ||
		              (strstr(info.name, "Radeon Pro Vega 16") != NULL) ||
		              (strstr(info.name, "Radeon Pro Vega 20") != NULL) ||
		              (strstr(info.name, "Radeon Pro 5300M") != NULL) ||
		              (strstr(info.name, "Radeon Pro 5500M") != NULL) ||
		              (strstr(info.name, "Radeon Pro 5600M") != NULL)) )  )   ) ||
		     (        (modelCString != NULL) && (strstr((const char *)modelCString, "MacPro6,1") != NULL) && (info.online == 0) &&
		             ((strstr(info.name, "FirePro D300") != NULL) ||
		              (strstr(info.name, "FirePro D500") != NULL) ||
		              (strstr(info.name, "FirePro D700") != NULL))   )    );
		
		if (wasBetterVirtualScreenFound)
		{
			CGLSetVirtualScreen(newContext, info.virtualScreen);
			__hostRendererID = info.rendererID;
			strncpy(__hostRendererString, (const char *)info.name, sizeof(__hostRendererString));
			printf("Found Better OpenGL Renderer: [0x%08X] %s\n", __hostRendererID, __hostRendererString);
			break;
		}
	}
	
	// If we couldn't find a better virtual screen for our rendering, then just revert to the default one.
	if (!wasBetterVirtualScreenFound)
	{
		CGLSetVirtualScreen(newContext, defaultVirtualScreen);
	}
	
	// We're done! Report success and return.
	printf("%s: OpenGL context creation successful.\n\n", ctxString);
	free(rendererInfo);
	free(modelCString);
	
	result = true;
	return result;
}

bool cgl_initOpenGL_StandardAuto()
{
	bool isContextCreated = __cgl_initOpenGL(kCGLOGLPVersion_GL4_Core);
	
	if (!isContextCreated)
	{
		isContextCreated = __cgl_initOpenGL(kCGLOGLPVersion_3_2_Core);
	}
	
	if (!isContextCreated)
	{
		isContextCreated = __cgl_initOpenGL(kCGLOGLPVersion_Legacy);
	}
	
	return isContextCreated;
}

bool cgl_initOpenGL_LegacyAuto()
{
	return __cgl_initOpenGL(kCGLOGLPVersion_Legacy);
}

bool cgl_initOpenGL_3_2_CoreProfile()
{
	return __cgl_initOpenGL(kCGLOGLPVersion_3_2_Core);
}

void cgl_deinitOpenGL()
{
	if (OSXOpenGLRendererContext == NULL)
	{
		return;
	}
	
	CGLSetCurrentContext(NULL);
	SILENCE_DEPRECATION_MACOS_10_7( CGLReleasePBuffer(OSXOpenGLRendererPBuffer) );
	OSXOpenGLRendererPBuffer = NULL;
	
	CGLReleaseContext(OSXOpenGLRendererContext);
	OSXOpenGLRendererContext = NULL;
	OSXOpenGLRendererContextPrev = NULL;
}

bool cgl_beginOpenGL()
{
	OSXOpenGLRendererContextPrev = CGLGetCurrentContext();
	CGLSetCurrentContext(OSXOpenGLRendererContext);
	
	return true;
}

void cgl_endOpenGL()
{
#ifndef PORT_VERSION_OS_X_APP
	// The OpenEmu plug-in needs the context reset after 3D rendering since OpenEmu's context
	// is assumed to be the default context. However, resetting the context for our standalone
	// app can cause problems since the core emulator's context is assumed to be the default
	// context. So reset the context for OpenEmu and skip resetting for us.
	CGLSetCurrentContext(OSXOpenGLRendererContextPrev);
#endif
}

bool cgl_framebufferDidResizeCallback(const bool isFBOSupported, size_t w, size_t h)
{
	bool result = false;
	
	if (isFBOSupported)
	{
		result = true;
		return result;
	}
	
	if (IsOSXVersionSupported(10, 13, 0))
	{
		printf("Mac OpenGL: P-Buffers cannot be created on macOS v10.13 High Sierra and later.\n");
		return result;
	}
	
	// Create a PBuffer if FBOs are not supported.
	SILENCE_DEPRECATION_MACOS_10_7( CGLPBufferObj newPBuffer = NULL );
	SILENCE_DEPRECATION_MACOS_10_7( CGLError error = CGLCreatePBuffer((GLsizei)w, (GLsizei)h, GL_TEXTURE_2D, GL_RGBA, 0, &newPBuffer) );
	
	if ( (newPBuffer == NULL) || (error != kCGLNoError) )
	{
		printf("Mac OpenGL: ERROR - Could not create the P-Buffer: %s\n", CGLErrorString(error));
		return result;
	}
	else
	{
		GLint virtualScreenID = 0;
		CGLGetVirtualScreen(OSXOpenGLRendererContext, &virtualScreenID);
		SILENCE_DEPRECATION_MACOS_10_7( CGLSetPBuffer(OSXOpenGLRendererContext, newPBuffer, 0, 0, virtualScreenID) );
	}
	
	SILENCE_DEPRECATION_MACOS_10_7( CGLPBufferObj oldPBuffer = OSXOpenGLRendererPBuffer );
	OSXOpenGLRendererPBuffer = newPBuffer;
	SILENCE_DEPRECATION_MACOS_10_7( CGLReleasePBuffer(oldPBuffer) );
	
	result = true;
	return result;
}
