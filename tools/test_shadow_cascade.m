// Compile the translated test shader and check the PCF scale on the actual GPU.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2); NSError *error=nil;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error]; assert(source);
    assert([device newLibraryWithSource:source options:nil error:&error]);
    NSRange start=[source rangeOfString:@"static inline float2 shadow_cascade_uv_scale"];
    NSRange end=[source rangeOfString:@"fragment FOut main0"];
    assert(start.location!=NSNotFound && end.location>start.location);
    NSString *helper=[source substringWithRange:NSMakeRange(start.location,end.location-start.location)];
    source=[@"#include <metal_stdlib>\nusing namespace metal;\n" stringByAppendingString:helper];
    source=[source stringByAppendingString:@"kernel void check(constant uint4*m[[buffer(0)]],device float2*out[[buffer(1)]],uint i[[thread_position_in_grid]]){out[i]=shadow_cascade_ratio(m,i);}"];
    id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error]; assert(lib);
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"check"] error:&error]; assert(pipeline);
    id<MTLBuffer> matrices=[device newBufferWithLength:192 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];
    for(unsigned test=0;test<6;test++) {
        float *m=matrices.contents; memset(m,0,192);
        for(unsigned layer=0;layer<3;layer++) m[layer*16]=m[layer*16+5]=m[layer*16+10]=m[layer*16+15]=1;
        m[16]=.5f;m[21]=.25f;
        if(test==1)m[31]=2;       // different homogeneous W
        if(test==2)m[19]=.1f;     // perspective: keep original radius
        if(test==3)m[16]=NAN;
        if(test==4)m[0]=0;
        if(test==5)m[16]=2;       // never widen a narrower cascade's filter
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];[enc setBuffer:matrices offset:0 atIndex:0];[enc setBuffer:output offset:0 atIndex:1];
        [enc dispatchThreads:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];assert(!cb.error);
        float *r=output.contents;assert(r[0]==1 && r[1]==1 && r[6]==1 && r[7]==1);
        float x=test==0?.5f:test==1?.25f:1, y=test==0||test==5?.25f:test==1?.125f:1;
        assert(fabsf(r[2]-x)<1e-5 && fabsf(r[3]-y)<1e-5);
    }
    puts("PASS: Metal shader compilation and 6 GPU radius/fallback cases");
}}
