// 桌面层组件"点不动/拖不动"时，先分清是代码问题还是被遮挡。
// CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly) 按"从前到后"返回，所以只要看
// 第一个盖住组件中心点的窗口是不是它自己。实测：全屏的远程桌面窗口（UURemoteServer）压在
// 桌面图标层之上时，点击根本送不到组件 —— 这时改拖拽代码是没用的。
// 三块组件一起查：遮挡是共因，如果只有某一块被挡，那就不是遮挡。
// 用法：probe_occlusion   （退出码 0 = 三块都没被挡，1 = 有被挡的）
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

static CGRect RectOf(id b){ CGRect r=CGRectZero; if(b) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)b,&r); return r; }

int main(void){ @autoreleasepool{
  CFArrayRef a=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID);
  CFIndex n=CFArrayGetCount(a);
  struct { const char *name; double w,h; } kinds[3] = {
      {"卡片面板",600,241},{"活动监视器",432,294},{"弹药库",432,294} };
  // 先把三块组件自己的窗口找出来（记下它们在列表里的下标，越小说明越靠上）
  NSInteger selfIdx[3]; CGRect selfRect[3]; BOOL found[3]={NO,NO,NO};
  for (CFIndex i=0;i<n;i++){
    CFDictionaryRef d=CFArrayGetValueAtIndex(a,i);
    NSString *ow=(__bridge NSString*)CFDictionaryGetValue(d,kCGWindowOwnerName);
    if(![ow isEqualToString:@"DeskBoard"]) continue;
    CGRect r=RectOf(CFDictionaryGetValue(d,kCGWindowBounds));
    for(int k=0;k<3;k++){
      if(found[k]) continue;
      if(fabs(r.size.width-kinds[k].w)<2.0 && fabs(r.size.height-kinds[k].h)<2.0){
        selfIdx[k]=i; selfRect[k]=r; found[k]=YES; break; }
    }
  }
  int blocked=0;
  for(int k=0;k<3;k++){
    if(!found[k]){ printf("— %-10s 当前没有可检的窗口（隐藏或被自动收起）\n",kinds[k].name); continue; }
    CGPoint c=CGPointMake(CGRectGetMidX(selfRect[k]),CGRectGetMidY(selfRect[k]));
    NSString *who=nil; NSInteger at=-1;
    for(CFIndex i=0;i<selfIdx[k];i++){
      CFDictionaryRef d=CFArrayGetValueAtIndex(a,i);
      CGRect r=RectOf(CFDictionaryGetValue(d,kCGWindowBounds));
      if(r.size.width<5||r.size.height<5) continue;
      if(CGRectContainsPoint(r,c)){
        who=(__bridge NSString*)CFDictionaryGetValue(d,kCGWindowOwnerName); at=(NSInteger)i; break; }
    }
    if(who){ blocked++; printf("✗ %-10s bounds=(%.0f,%.0f %.0fx%.0f) 被挡：第 %ld 层 %s\n",
             kinds[k].name,selfRect[k].origin.x,selfRect[k].origin.y,selfRect[k].size.width,selfRect[k].size.height,(long)at,who.UTF8String); }
    else printf("✓ %-10s bounds=(%.0f,%.0f %.0fx%.0f) 中心无遮挡（自己就是最上面那个）\n",
             kinds[k].name,selfRect[k].origin.x,selfRect[k].origin.y,selfRect[k].size.width,selfRect[k].size.height);
  }
  printf("\n%s\n", blocked? "有组件被挡 —— 先处理遮挡，再谈拖拽代码" : "三块都没被挡 —— 遮挡不是原因，往代码里查");
  return blocked?1:0;
}}
