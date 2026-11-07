#import <Metal/Metal.h>
#include "../runtime/nvn/geometry_motion_history.h"
#include <assert.h>
int main(void){@autoreleasepool{
 id<MTLDevice>d=MTLCreateSystemDefaultDevice();assert(d);FgGeometryBinding b={0};
 assert(!fg_geometry_acquire(d,1,1,0,&b));
 assert(fg_geometry_acquire(d,1,1,4,&b)&&!b.has_previous&&b.vertex_count==4);
 id<MTLBuffer>first=b.current;assert(fg_geometry_model(1,1,100));fg_geometry_written(1,1);
 assert(fg_geometry_acquire(d,1,1,4,&b)&&b.current==first&&!b.has_previous);
 assert(fg_geometry_acquire(d,1,2,4,&b)&&b.previous==first&&b.has_previous);
 assert(fg_geometry_model(1,2,101));fg_geometry_written(1,2);assert(fg_geometry_model(1,2,101));
 assert(!fg_geometry_model(1,2,102));assert(!fg_geometry_frame_valid(2));
 assert(fg_geometry_acquire(d,1,3,4,&b)&&!b.has_previous);
 assert(fg_geometry_frame_valid(3));assert(fg_geometry_model(1,3,103));
 assert(fg_geometry_acquire(d,1,5,4,&b)&&!b.has_previous);
 assert(fg_geometry_acquire(d,1,6,8,&b)&&!b.has_previous&&b.vertex_count==8);
 fg_geometry_reset();assert(fg_geometry_acquire(d,1,7,4,&b)&&!b.has_previous);
 fg_geometry_reset();
 for(unsigned i=0;i<10;i++)assert(fg_geometry_acquire(d,100+i,10,262144,&b));
 assert(!fg_geometry_acquire(d,200,10,262144,&b));
 assert(fg_geometry_acquire(d,200,13,4,&b)); // stale entries are evicted
 fg_geometry_reset();puts("PASS: geometry history identity, frames, ambiguity, bounds and budget");
}}
