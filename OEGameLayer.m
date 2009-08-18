/*
 Copyright (c) 2009, OpenEmu Team
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEGameLayer.h"
#import "GameCore.h"
#import "GameDocument.h"
#import "OECompositionPlugin.h"


@implementation OEGameLayer

@synthesize gameCore, owner, gameCIImage;
@synthesize docController;
- (BOOL)vSyncEnabled
{
    return vSyncEnabled;
}

- (void)setVSyncEnabled:(BOOL)value
{
    vSyncEnabled = value;
    if(layerContext != nil)
    {
        GLint sync = value;
        CGLSetParameter(layerContext, kCGLCPSwapInterval, &sync);
    }
}

- (NSString *)filterName
{
    return filterName;
}

- (QCComposition *)composition
{
    return [[OECompositionPlugin compositionPluginWithName:filterName] composition];
}

- (void)setFilterName:(NSString *)aName
{
    NSLog(@"setting filter name");
    [filterName autorelease];
    filterName = [aName retain];
    
    // since we changed the filtername, if we have a context (ie we are active) lets make a new QCRenderer...
    if(layerContext != NULL)
    {
        CGLSetCurrentContext(layerContext);
        CGLLockContext(layerContext);
            
        if(filterRenderer && (filterRenderer != nil))
        {
            NSLog(@"releasing old filterRenderer");

            [filterRenderer release];
            filterRenderer = nil;
        }    
        
        NSLog(@"making new filter renderer");
        
		// this will be responsible for our rendering... weee...    
		QCComposition *compo = [self composition];
        
		if(compo != nil)
        {
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
            filterRenderer = [[QCRenderer alloc] initWithCGLContext:layerContext 
														pixelFormat:CGLGetPixelFormat(layerContext)
														 colorSpace:space
														composition:compo];
            CGColorSpaceRelease(space);
        }
        
		if (filterRenderer == nil)
			NSLog(@"Warning: failed to create our filter QCRenderer");
		
		if (![[filterRenderer inputKeys] containsObject:@"OEImageInput"])
			NSLog(@"Warning: invalid Filter composition. Does not contain valid image input key");
		
		if([[filterRenderer outputKeys] containsObject:@"OEMousePositionX"] && [[filterRenderer outputKeys] containsObject:@"OEMousePositionY"])
		{
			NSLog(@"filter has mouse output position keys");
			filterHasOutputMousePositionKeys = TRUE;
		}
		else
			filterHasOutputMousePositionKeys = FALSE;
		
        CGLUnlockContext(layerContext);
    }
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat
{
    NSLog(@"initing GL context and shaders");
    
    // ignore the passed in pixel format. We will make our own.
 
    layerContext = [super copyCGLContextForPixelFormat:pixelFormat];
    
    // we need to hold on to this for later.
    CGLRetainContext(layerContext);
    
    [self setVSyncEnabled:vSyncEnabled];
        
    CGLSetCurrentContext(layerContext); 
    CGLLockContext(layerContext);

	// our QCRenderer 'filter'
	[self setFilterName:filterName];
	  	
	// create our texture we will be updating in drawInCGLContext:
	[self createTexture];
	
	[self createCorrectionFBO];
	
    CGLUnlockContext(layerContext);
    
    return layerContext;
}

-(CGSize)preferredFrameSize
{
    CALayer* superlayer = self.superlayer;
    
    NSSize aspect = NSMakeSize([gameCore screenWidth], [gameCore screenHeight]);
    
    if(superlayer.bounds.size.width * (aspect.width * 1.0/aspect.height) > superlayer.bounds.size.height * (aspect.width * 1.0/aspect.height))
        return CGSizeMake(superlayer.bounds.size.height * (aspect.width * 1.0/aspect.height), superlayer.bounds.size.height);
    else
        return CGSizeMake( superlayer.bounds.size.width, superlayer.bounds.size.width * (aspect.height* 1.0/aspect.width));

	//NSLog(@"%d",[[gameCore document] windowScale]);
	//return CGSizeMake([[gameCore document] windowScale] * [gameCore screenWidth] , [[gameCore document] windowScale] * [gameCore screenHeight]);
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)glContext pixelFormat:(CGLPixelFormatObj)pixelFormat forLayerTime:(CFTimeInterval)timeInterval displayTime:(const CVTimeStamp *)timeStamp
{
    // im not sure exactly how the frameFinished stuff works.
    // im tempted to say we should always return yes, 
    // and just only upload a video buffer texture
    // if frameFinished is true, etc.
    
    //return [gameCore frameFinished];
    return YES;
}

- (void)drawInCGLContext:(CGLContextObj)glContext pixelFormat:(CGLPixelFormatObj)pixelFormat forLayerTime:(CFTimeInterval)timeInterval displayTime:(const CVTimeStamp *)timeStamp
{
    // rendering time for QC filters..
    time = [NSDate timeIntervalSinceReferenceDate];
    
    if(startTime == 0)
    {
        startTime = time;
        time = 0;
    }
    else
        time -= startTime;    
    
    CGLSetCurrentContext(glContext);// (glContext);
    CGLLockContext(glContext);
    
    // our filters always clear, so we dont. Saves us an expensive buffer setting.
    // glClearColor(0.0, 0.0, 0.0, 0.0);
    // glClear(GL_COLOR_BUFFER_BIT); // Clear The Screen
    
    // update our gameBuffer texture
    [self uploadGameBufferToTexture];

	// we may want to do some logic here to see if we actually need to pass the correctionTexure or gameTexture.
	// would save us a n FBO pass.
	
	// square pixel texture ready to go:
	[self correctPixelAspectRatio];
	
	/*CGSize size;
	if([gameCore respondsToSelector:@selector(outputSize)])
		size = CGSizeMake([gameCore outputSize].width, [gameCore outputSize].height);
	else
		size = [gameCore sourceRect].size;
	*/
	
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    self.gameCIImage = [CIImage imageWithTexture:correctionTexture size:CGSizeMake(gameCore.screenWidth, gameCore.screenHeight) flipped:YES colorSpace:space];
	CGColorSpaceRelease(space);
    if(filterRenderer != nil)
    {
		// NSPoint mouseLocation = [event locationInWindow];
		NSPoint mouseLocation = [[owner	gameWindow] mouseLocationOutsideOfEventStream];
		mouseLocation.x /= [[[owner gameWindow] contentView] frame].size.width;
		mouseLocation.y /= [[[owner gameWindow] contentView] frame].size.height;
		NSMutableDictionary* arguments = [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSValue valueWithPoint:mouseLocation], QCRendererMouseLocationKey, [[owner gameWindow] currentEvent], QCRendererEventKey, nil];
		
        // [filterRenderer setValue:[gameCIImage imageByCroppingToRect:cropRect] forInputKey:@"OEImageInput"];    
		[filterRenderer setValue:self.gameCIImage forInputKey:@"OEImageInput"];
        [filterRenderer renderAtTime:time arguments:arguments];
		
		if(filterHasOutputMousePositionKeys)
		{
			NSPoint mousePoint;
			mousePoint.x = [[filterRenderer valueForOutputKey:@"OEMousePositionX"] floatValue];
			mousePoint.y = [[filterRenderer valueForOutputKey:@"OEMousePositionY"] floatValue];
			[gameCore setMousePosition:mousePoint];
		}
	}
    
    // super calls flush for us.
    [super drawInCGLContext:glContext pixelFormat:pixelFormat forLayerTime:timeInterval displayTime:timeStamp];
	
    CGLUnlockContext(glContext);
}

- (void)releaseCGLContext:(CGLContextObj)glContext
{
    CGLSetCurrentContext(glContext);
    CGLLockContext(glContext);
   
	// delete gl resources.
    glDeleteTextures(1, &gameTexture);
	
	glDeleteFramebuffersEXT(1, &correctionFBO);
	    
    CGLUnlockContext(glContext);    
    
    NSLog(@"deleted GL context");
    
    [super releaseCGLContext:glContext];
}

- (void)dealloc
{
    [self unbind:@"filterName"];
    [self unbind:@"vSyncEnabled"];

	[filterRenderer release];
	
    CGLReleaseContext(layerContext);
    [docController release];
    [gameCore release];
    [super dealloc];
}

- (void)createTexture
{
	glPushAttrib(GL_ALL_ATTRIB_BITS);
	
    // create our texture 
    glEnable(GL_TEXTURE_RECTANGLE_EXT);
    glGenTextures(1, &gameTexture);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, gameTexture);
	
    // with storage hints & texture range -- assuming image depth should be 32 (8 bit rgba + 8 bit alpha ?) 
    glTextureRangeAPPLE(GL_TEXTURE_RECTANGLE_EXT,  [gameCore bufferWidth] * [gameCore bufferHeight] * (32 >> 3), [gameCore videoBuffer]); 
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_CACHED_APPLE);
    glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);
	
    // proper tex params.
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
	
    glTexImage2D( GL_TEXTURE_RECTANGLE_EXT, 0, [gameCore internalPixelFormat], [gameCore bufferWidth], [gameCore bufferHeight], 0, [gameCore pixelFormat], [gameCore pixelType], [gameCore videoBuffer]);
    
    // unset our client storage options storage
    // these fucks were causing our FBOs to fail.
    glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_STORAGE_HINT_APPLE , GL_STORAGE_PRIVATE_APPLE);
    glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);
	
	glPopAttrib();
	
	// cache our texture size so we can tell if it changed behind our backs..
	cachedTextureSize = CGSizeMake([gameCore bufferWidth], [gameCore bufferHeight]);
}

- (void)uploadGameBufferToTexture
{
	// only do a texture submit if we have a new frame...
    if([gameCore frameFinished])
    {    
		// check to see if our gameCore switched to hi-res mode, or did anything fucked up to the texture size.
		if((cachedTextureSize.width != [gameCore bufferWidth]) || (cachedTextureSize.height != [gameCore bufferHeight]))
		{
			NSLog(@"Our gamecore imaeg size changed.. rebuilding texture...");
			glDeleteTextures(1, &gameTexture);
			[self createTexture];
		}
		
        // update our gamebuffer texture
        glEnable(GL_TEXTURE_RECTANGLE_EXT);
        glBindTexture(GL_TEXTURE_RECTANGLE_EXT, gameTexture);
		glTexSubImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, 0, 0, [gameCore bufferWidth], [gameCore bufferHeight], [gameCore pixelFormat], [gameCore pixelType], [gameCore videoBuffer]); 
    }
}

- (void) createCorrectionFBO
{
	DLog(@"creating FBO");
	
	glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &previousFBO);    
    
    GLenum status;
    GLuint name;
	
    glGenTextures(1, &name);
    glBindTexture(GL_TEXTURE_RECTANGLE_EXT, name);
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA8, 640, 480, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    
    // Create temporary FBO to render in texture 
    glGenFramebuffersEXT(1, &correctionFBO);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, correctionFBO);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_EXT, name, 0);
    
    status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    if(status != GL_FRAMEBUFFER_COMPLETE_EXT)
    {    
        NSLog(@"Cannot create FBO");
        NSLog(@"OpenGL error %04X", status);
		
        glDeleteFramebuffersEXT(1, &correctionFBO);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, previousFBO);
        glDeleteTextures(1, &name);
    }    
    
    // cleanup
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, previousFBO);
	glDeleteTextures(1, &name); // delete temp test texture.
}


// this renders our potentially oddly formatted gameTexture to a FBO to correct for any offsets or odd pixel aspect ratios.
- (void) correctPixelAspectRatio
{
	// the size of our output image, we may need/want to put in accessors for texture coord
	// offsets from the game core should the image we want be 'elsewhere' within the main texture. 
	CGRect cropRect = [gameCore sourceRect];
	
	//    GLenum  status;
    
    // save our current GL state
    glPushAttrib(GL_ALL_ATTRIB_BITS);
    
    // re-create texture to render into 
	// we do this every frame because emus like SNES can change the output size on us at any moment.
	// we also delete the texture here because we dont know when our CIImage will be released later, so we do it in the next frame.

	glDeleteTextures(1, &correctionTexture);
	glGenTextures(1, &correctionTexture); // yes this is retarded but... 
	
	glBindTexture(GL_TEXTURE_RECTANGLE_EXT, correctionTexture);    
    glTexImage2D(GL_TEXTURE_RECTANGLE_EXT, 0, GL_RGBA8, gameCore.screenWidth, gameCore.screenHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL); 
    
    // bind our FBO
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, correctionFBO);
    
    // attach our just created texture
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_EXT, correctionTexture, 0);
    
    // Assume FBOs JUST WORK, because we checked on startExecution    
	// status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);    
	// if(status == GL_FRAMEBUFFER_COMPLETE_EXT)
    {    
        // Setup OpenGL states 
        glViewport(0, 0, gameCore.screenWidth,  gameCore.screenHeight);
        glMatrixMode(GL_PROJECTION);
        glPushMatrix();
        glLoadIdentity();
        glOrtho(0, gameCore.screenWidth, 0, gameCore.screenHeight, -1, 1);
		
        glMatrixMode(GL_MODELVIEW);
        glPushMatrix();
        glLoadIdentity();
        
		// dont bother clearing. we dont have any alpha so we just write over the buffer contents. saves us an expensive write.
		// glClearColor(0.0, 0.0, 0.0, 0.0);
		// glClear(GL_COLOR_BUFFER_BIT);        
		
		glActiveTexture(GL_TEXTURE0);
		glEnable(GL_TEXTURE_RECTANGLE_EXT);
        glBindTexture(GL_TEXTURE_RECTANGLE_EXT, gameTexture);
		
		// do a nearest neighbor interp.
		glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_MAG_FILTER, GL_NEAREST);		
		
        glColor4f(1.0, 1.0, 1.0, 1.0);

		// why do we need it ?
		glDisable(GL_BLEND);
		
		glBegin(GL_QUADS);    // Draw A Quad
        {
			glMultiTexCoord2f(GL_TEXTURE0, cropRect.origin.x, cropRect.origin.y);
			// glTexCoord2f(0.0f, 0.0f);
			glVertex3f(0.0f, 0.0f, 0.0f);
			
			glMultiTexCoord2f(GL_TEXTURE0, cropRect.size.width + cropRect.origin.x, cropRect.origin.y);
			// glTexCoord2f(pixelsWide, 0.0f );
			glVertex3f(gameCore.screenWidth, 0.0f, 0.0f);
			
			glMultiTexCoord2f(GL_TEXTURE0, cropRect.size.width + cropRect.origin.x, cropRect.size.height + cropRect.origin.y);
			// glTexCoord2f(pixelsWide, pixelsHigh);
			glVertex3f(gameCore.screenWidth, gameCore.screenHeight, 0.0f);
			
			glMultiTexCoord2f(GL_TEXTURE0, cropRect.origin.x, cropRect.size.height + cropRect.origin.y);
			// glTexCoord2f(0.0f, pixelsHigh);
			glVertex3f(0.0f, gameCore.screenHeight, 0.0f);
        }
        glEnd(); // Done Drawing The Quad
		
		// Restore OpenGL states 
        glMatrixMode(GL_MODELVIEW);
        glPopMatrix();
        
		glMatrixMode(GL_PROJECTION);
        glPopMatrix();
    }
	
	// restore states
	glPopAttrib();        
	
	// flush to make sure FBO texture attachment is finished being rendered.
	glFlushRenderAPPLE();
	
	// back to our original FBO
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, previousFBO);
    
    // Check for OpenGL errors 
	/*    status = glGetError();
	 if(status)
	 {
	 NSLog(@"FrameBuffer OpenGL error %04X", status);
	 glDeleteTextures(1, &name);
	 name = 0;
	 }
	 */    
}

- (NSImage*) imageForCurrentFrame
{	
	if( !self.gameCIImage )
		return nil;
	
	unsigned char * outputPixels;
	
	int width = [self.gameCIImage extent].size.width; 
	int height = [self.gameCIImage extent].size.height;  
	
	outputPixels = calloc(width * height, 4);
	
    CGLSetCurrentContext(layerContext);
	
	CGLLockContext(layerContext);
	glFlush();
	glBindTexture(GL_TEXTURE_RECTANGLE_ARB, correctionTexture);
	
	glGetTexImage(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA, GL_UNSIGNED_INT_8_8_8_8_REV, outputPixels);
	glFlush();
	CGLUnlockContext(layerContext);

	NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&outputPixels 
																	pixelsWide:width 
																	pixelsHigh:height
																 bitsPerSample:8
															   samplesPerPixel:4
																	  hasAlpha:YES
																	  isPlanar:NO
																colorSpaceName:NSCalibratedRGBColorSpace
																   bytesPerRow:4 * width
																  bitsPerPixel:32];
	NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
	[image addRepresentation:rep];
//	free(outputPixels);
	//[[image TIFFRepresentation] writeToFile:@"/Users/jweinberg/test1.tiff" atomically:YES];
	return image;
}
@end
