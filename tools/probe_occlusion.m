// 桌面层组件"点不动/拖不动"时，先分清是代码问题还是被遮挡。
// CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly) 按"从前到后"返回，所以只要看
// 第一个盖住组件中心点的窗口是不是它自己。实测：全屏的远程桌面窗口（UURemoteServer）压在
// 桌面图标层之上时，点击根本送不到组件 —— 这时改拖拽代码是没用的。
// 用法：probe_occlusion   （退出码 0 = 没被挡，1 = 被挡）
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
int main(void){ @autoreleasepool{
  CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
  CGRect mon=CGRectZero; NSInteger monIdx=-1;
  for(CFIndex i=0;i<CFArrayGetCount(a);i++){CFDictionaryRef d=CFArrayGetValueAtIndex(a,i);
    NSString*ow=(__bridge NSString*)CFDictionaryGetValue(d,kCGWindowOwnerName);
    CFDictionaryRef b=CFDictionaryGetValue(d,kCGWindowBounds); CGRect r=CGRectZero; if(b)CGRectMakeWithDictionaryRepresentation(b,&r);
    if([ow isEqualToString:@"DeskBoard"] && r.size.width>430&&r.size.width<440&&r.size.height>290&&r.size.height<300){mon=r;monIdx=i;break;}}
  if(monIdx<0){printf("没找到活动监视器窗口\n");return 2;}
  CGPoint c=CGRectGetMidX(mon)>0?CGPointMake(CGRectGetMidX(mon),CGRectGetMidY(mon)):CGPointZero;
  printf("活动监视器 bounds=(%.0f,%.0f %.0fx%.0f) 中心(%.0f,%.0f)\n",mon.origin.x,mon.origin.y,mon.size.width,mon.size.height,c.x,c.y);
  for(CFIndex i=0;i<monIdx;i++){CFDictionaryRef d=CFArrayGetValueAtIndex(a,i);
    NSString*ow=(__bridge NSString*)CFDictionaryGetValue(d,kCGWindowOwnerName);
    CFDictionaryRef b=CFDictionaryGetValue(d,kCGWindowBounds); CGRect r=CGRectZero; if(b)CGRectMakeWithDictionaryRepresentation(b,&r);
    if(r.size.width<5||r.size.height<5) continue;
    if(CGRectContainsPoint(r,c)){printf("✗ 它上面第 %ld 层就压着它：%s bounds=(%.0f,%.0f %.0fx%.0f)\n",(long)i,ow.UTF8String,r.origin.x,r.origin.y,r.size.width,r.size.height);return 1;}
  }
  printf("✓ 从最顶层往下数，第一个盖到中心点的就是它自己 —— 没被遮挡，能点到\n"); return 0;
}}
