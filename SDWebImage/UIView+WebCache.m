/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCache.h"

#if SD_UIKIT || SD_MAC

#import "objc/runtime.h"
#import "UIView+WebCacheOperation.h"

static char imageURLKey;

#if SD_UIKIT
static char TAG_ACTIVITY_INDICATOR;
static char TAG_ACTIVITY_STYLE;
#endif
static char TAG_ACTIVITY_SHOW;

@implementation UIView (WebCache)

- (nullable NSURL *)sd_imageURL {
    return objc_getAssociatedObject(self, &imageURLKey);
}

// block：我亲切的把它比喻为：寄生虫。寄生虫的任务是寄生到函数内部，在合适的时间返回需要的东西，并执行预先设定好的事件
// 在给imageView赋值image时，不需要把imageView对象传入最深层的下载器内部，而只需要放置一个block，在下载器内部把image返回即可。
// 寄生虫1(block1)：setImageBlock
// 寄生虫2(block2)：progressBlock
// 寄生虫3(block3)：completedBlock
- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                      operationKey:(nullable NSString *)operationKey
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                         completed:(nullable SDExternalCompletionBlock)completedBlock {
    // 如果没有传key的话，则取self对应的Class类名，注意，这里取的不是父类的，而是子类FLAnimatedImageView的类名。
    NSString *validOperationKey = operationKey ?: NSStringFromClass([self class]);
    // 这个函数主要是取消这个key对应的上一个operation。
    [self sd_cancelImageLoadOperationWithKey:validOperationKey];
    // 给self的关联对象imageURLKey赋值url
    objc_setAssociatedObject(self, &imageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 这个if判断是一个按位与运算符，只有options != (SDWebImageDelayPlaceholder | otherOptions) 时才会满足条件，此时会直接把placeholder设置到view上显示。
    
    // 而当options == (SDWebImageDelayPlaceholder | otherOptions)会怎么样呢？此时placehloder不会显示在view上，在image下载解码这段时间内，view是空白的，当image下载解码完毕后，如果image存在，就会设置在view上显示image，否则，会在view上显示placeholder。
    if (!(options & SDWebImageDelayPlaceholder)) {
        // 这个dispatch_main_async_safe宏定义是保证block内部代码一定是在主线程上执行。
        dispatch_main_async_safe(^{
            // 在这里，sd_setImage这个函数内部是把placeholder图片设置给UIImageView或者UIButton。里面直接触发了block1：setImageBlock的回调。
            [self sd_setImage:placeholder imageData:nil basedOnClassOrViaCustomSetImageBlock:setImageBlock];
        });
    }
    
    if (url) {
        // check if activityView is enabled or not
        //  如果UIActivityIndicatorView不存在，就在自身中心点创建一个，并让它显示动画转动
        if ([self sd_showActivityIndicatorView]) {
            [self sd_addActivityIndicator];
        }
        
        __weak __typeof(self)wself = self;
        // operation就是SDWebImageCombinedOperation类的对象。只是说operation作为了别人的delegate实现了别人的协议，所以成了id型的了。我觉得这并不公平，不该抹除它的身份/斜眼笑。
        
        // 这里又创建了一个block4，就是(nullable SDInternalCompletionBlock)completedBlock，这里已经写出了回调后该做的事情。但是由于block2(progressBlock)和block4(completedBlock)都无法在当前函数中得到自己需要的数据，所以他们都继续寄生到了函数loadImageWithURL:options:progress:completed: 的内部。
        
        // 注意这里的两个completedBlock是不一样的，一个是block3(SDExternalCompletionBlock)，一个是block4(SDInternalCompletionBlock)。block3(completedBlock)将会在下面block4的回调方法里得到自己想要的数据而主动触发它自己的回调。
        
        // 目前已经或将会触发的block是：block1(setImageBlock)、block3(completedBlock)
        // 未被触发的block是：block2(progressBlock)、block4(completedBlock)，未被触发的block将会继续往更深处传递。
        
        id <SDWebImageOperation> operation = [SDWebImageManager.sharedManager loadImageWithURL:url options:options progress:progressBlock completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
            
            // 这里假设block4(completedBlock)已经得到了想要的数据而触发了回调。
            __strong __typeof (wself) sself = wself;
            // 移除view上的UIActivityIndicatorView视图
            [sself sd_removeActivityIndicator];
            // 如果view已经销毁，那个将不会有赋值image的操作。
            if (!sself) {
                return;
            }
            // 主线程执行
            dispatch_main_async_safe(^{
                if (!sself) {
                    return;
                }
                // (options & SDWebImageAvoidAutoSetImage)：表示当options == (SDWebImageAvoidAutoSetImage | otherOptions)时。这里为什么不直接用if(options == SDWebImageAvoidAutoSetImage)？因为option可以多选，比如如果option =  SDWebImageAvoidAutoSetImage | SDWebImageTransformAnimatedImage，那么肯定也希望它能满足条件。
                
                // 当你不需要库内部给你的view控件自动赋值image，而是在completedBlock里手动给控件的image属性赋值的话，你就可以选择SDWebImageAvoidAutoSetImage这个option。
                if (image && (options & SDWebImageAvoidAutoSetImage) && completedBlock) {
                    completedBlock(image, error, cacheType, url);
                    return;
                }
                // image存在的话，会再次执行sd_setImage方法，这个方法内部要做的事情就是把image显示在view上，这一点我们上面已经说过了。里面直接触发了block1：setImageBlock的回调。
                else if (image) {
                    [sself sd_setImage:image imageData:data basedOnClassOrViaCustomSetImageBlock:setImageBlock];
                    [sself sd_setNeedsLayout];
                } else {
                    if ((options & SDWebImageDelayPlaceholder)) {
                        [sself sd_setImage:placeholder imageData:nil basedOnClassOrViaCustomSetImageBlock:setImageBlock];
                        [sself sd_setNeedsLayout];
                    }
                }
                
                // 触发block3(completedBlock)的回调
                if (completedBlock && finished) {
                    completedBlock(image, error, cacheType, url);
                }
            });
        }];
        
        // 上面的一切都是在分析回调内部干的事情，但代码的执行顺序是一开始执行到这里的。
        // 这个函数主要是取消这个key对应的上一个operation，并把operation用这个key存在一个字典里保存起来。
        //TODO: 并没有完全搞明白key的设定的意思。
        [self sd_setImageLoadOperation:operation forKey:validOperationKey];
    }
    
    // 如果URL不存在，则会抛出异常。记住如果placeholder有值的话，前面已经把placeholder显示给了view
    else {
        dispatch_main_async_safe(^{
            [self sd_removeActivityIndicator];
            if (completedBlock) {
                NSError *error = [NSError errorWithDomain:SDWebImageErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : @"Trying to load a nil url"}];
                completedBlock(nil, error, SDImageCacheTypeNone, url);
            }
        });
    }
}

- (void)sd_cancelCurrentImageLoad {
    [self sd_cancelImageLoadOperationWithKey:NSStringFromClass([self class])];
}

- (void)sd_setImage:(UIImage *)image imageData:(NSData *)imageData basedOnClassOrViaCustomSetImageBlock:(SDSetImageBlock)setImageBlock {
    if (setImageBlock) {
        // block1(setImageBlock)在这里得到了想要的数据，所以将会主动触发回调。
        // 立马回调到setImageBlock内部并return。其内部是给imageView设置这里的image。
        setImageBlock(image, imageData);
        return;
    }
    
    // 么有setImageBlock的话，手动把placeholer设置给imageView或UIButton
#if SD_UIKIT || SD_MAC
    if ([self isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)self;
        imageView.image = image;
    }
#endif
    
#if SD_UIKIT
    if ([self isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)self;
        [button setImage:image forState:UIControlStateNormal];
    }
#endif
}

- (void)sd_setNeedsLayout {
#if SD_UIKIT
    [self setNeedsLayout];
#elif SD_MAC
    [self setNeedsLayout:YES];
#endif
}

#pragma mark - Activity indicator

#pragma mark -
#if SD_UIKIT
- (UIActivityIndicatorView *)activityIndicator {
    return (UIActivityIndicatorView *)objc_getAssociatedObject(self, &TAG_ACTIVITY_INDICATOR);
}

- (void)setActivityIndicator:(UIActivityIndicatorView *)activityIndicator {
    objc_setAssociatedObject(self, &TAG_ACTIVITY_INDICATOR, activityIndicator, OBJC_ASSOCIATION_RETAIN);
}
#endif

- (void)sd_setShowActivityIndicatorView:(BOOL)show {
    objc_setAssociatedObject(self, &TAG_ACTIVITY_SHOW, @(show), OBJC_ASSOCIATION_RETAIN);
}

- (BOOL)sd_showActivityIndicatorView {
    return [objc_getAssociatedObject(self, &TAG_ACTIVITY_SHOW) boolValue];
}

#if SD_UIKIT
- (void)sd_setIndicatorStyle:(UIActivityIndicatorViewStyle)style{
    objc_setAssociatedObject(self, &TAG_ACTIVITY_STYLE, [NSNumber numberWithInt:style], OBJC_ASSOCIATION_RETAIN);
}

- (int)sd_getIndicatorStyle{
    return [objc_getAssociatedObject(self, &TAG_ACTIVITY_STYLE) intValue];
}
#endif

- (void)sd_addActivityIndicator {
#if SD_UIKIT
    dispatch_main_async_safe(^{
        if (!self.activityIndicator) {
            self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[self sd_getIndicatorStyle]];
            self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        
            [self addSubview:self.activityIndicator];
            
            [self addConstraint:[NSLayoutConstraint constraintWithItem:self.activityIndicator
                                                             attribute:NSLayoutAttributeCenterX
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:self
                                                             attribute:NSLayoutAttributeCenterX
                                                            multiplier:1.0
                                                              constant:0.0]];
            [self addConstraint:[NSLayoutConstraint constraintWithItem:self.activityIndicator
                                                             attribute:NSLayoutAttributeCenterY
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:self
                                                             attribute:NSLayoutAttributeCenterY
                                                            multiplier:1.0
                                                              constant:0.0]];
        }
        [self.activityIndicator startAnimating];
    });
#endif
}

- (void)sd_removeActivityIndicator {
#if SD_UIKIT
    dispatch_main_async_safe(^{
        if (self.activityIndicator) {
            [self.activityIndicator removeFromSuperview];
            self.activityIndicator = nil;
        }
    });
#endif
}

@end

#endif
