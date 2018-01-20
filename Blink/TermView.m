////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

#include <sys/ioctl.h>


#import "TermView.h"
#import "BKDefaults.h"
#import "BKSettingsNotifications.h"
#import "BKFont.h"
#import "BKTheme.h"
#import "TermJS.h"

@implementation BLWebView

- (BOOL)canResignFirstResponder
{
  return NO;
}

- (BOOL)becomeFirstResponder
{
  return NO;
}

@end


@interface TermView () <UIGestureRecognizerDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@end

@implementation TermView {
  WKWebView *_webView;

  UITapGestureRecognizer *_tapBackground;
  UILongPressGestureRecognizer *_longPressBackground;
  UIPinchGestureRecognizer *_pinchGesture;
  
  NSTimer *_pinchSamplingTimer;
  BOOL _focused;
  
  BOOL _jsIsBusy;
  dispatch_queue_t _jsQueue;
  NSMutableString *_jsBuffer;
  
  UIVisualEffectView *_overlayView;
  BOOL _readyToDelete;
}


- (id)initWithFrame:(CGRect)frame
{
  self = [super initWithFrame:frame];

  if (self) {
    
    _jsQueue = dispatch_queue_create(@"TermView.js".UTF8String, DISPATCH_QUEUE_SERIAL);
    _jsBuffer = [[NSMutableString alloc] init];

    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self _addWebView];
  }

  return self;
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  
  if (self.window.screen == [UIScreen mainScreen]) {
    [self _addGestures];
  }
}

- (BOOL)isDragging {
  return _webView.scrollView.panGestureRecognizer.state == UIGestureRecognizerStateRecognized;
}

- (BOOL)canBecomeFirstResponder {
  return NO;
}

- (void)_addWebView
{
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  configuration.selectionGranularity = WKSelectionGranularityCharacter;
  [configuration.userContentController addScriptMessageHandler:self name:@"interOp"];

  _webView = [[BLWebView alloc] initWithFrame:self.bounds configuration:configuration];
  
  _webView.navigationDelegate = self;
  _webView.scrollView.delaysContentTouches = NO;
  _webView.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  _webView.scrollView.panGestureRecognizer.minimumNumberOfTouches = 2;
  _webView.opaque = NO;
  _webView.backgroundColor = [UIColor clearColor];
  
  _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  
  [self addSubview:_webView];
}

- (UIView *)_overlayView
{
  if (!_overlayView) {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    _overlayView = [[UIVisualEffectView alloc] initWithEffect:effect];
    _overlayView.frame = self.bounds;
    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:nil];
    btn.tintColor = [UIColor redColor];
    UIToolbar * toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 50, 60)];
    toolbar.clipsToBounds = YES;
    toolbar.backgroundColor = [UIColor blackColor];
    toolbar.barTintColor = [UIColor blackColor];
    [toolbar setItems:@[btn]];
    [toolbar setBackgroundImage:[UIImage new]
      forToolbarPosition:UIToolbarPositionAny
      barMetrics:UIBarMetricsDefault];
    
    [toolbar setBackgroundColor:[UIColor clearColor]];
    toolbar.center = _webView.center;
    
    toolbar.transform = CGAffineTransformMakeScale(3.0, 3.0);
    [_overlayView.contentView addSubview:toolbar];
  }
  
  return _overlayView;
}

- (BOOL)readyToDelete
{
  return _readyToDelete;
}

- (void)setReadyToDelete:(BOOL)ready
{
  _readyToDelete = ready;
  if (ready) {
    UIView *overlay = [self _overlayView];
    [self addSubview:overlay];
    
    overlay.alpha = 0;
    
    [UIView animateWithDuration:0.3 animations:^{
      overlay.alpha = 0.6;
    }];
  } else {
    [UIView animateWithDuration:0.3 animations:^{
      _overlayView.alpha = 0;
    } completion:^(BOOL finished) {
      [_overlayView removeFromSuperview];
      _overlayView = nil;
    }];
  }
}

- (void)setFreezed:(BOOL)freezed
{
  BOOL enabled = !freezed;
  self.userInteractionEnabled = enabled;
  [_webView.scrollView setScrollEnabled:enabled];
  _webView.userInteractionEnabled = enabled;
  _pinchGesture.enabled = enabled;
  _longPressBackground.enabled = enabled;
  _tapBackground.enabled = enabled;
}

- (void)_addGestures
{
  if (!_tapBackground) {
    _tapBackground = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(activeControl:)];
    [_tapBackground setNumberOfTapsRequired:1];
    _tapBackground.delegate = self;
    [self addGestureRecognizer:_tapBackground];
  }

  if (!_longPressBackground) {
    _longPressBackground = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    _longPressBackground.delegate = self;
    [self addGestureRecognizer:_longPressBackground];
  }

  if (!_pinchGesture) {
    _pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    _pinchGesture.delegate = self;
    [self addGestureRecognizer:_pinchGesture];
  }
}

- (NSString *)title
{
  return _webView.title;
}

- (void)_evalJS:(NSString *)script completionHandler:(void (^ _Nullable)(_Nullable id, NSError * _Nullable error))completionHandler
{
  [_webView evaluateJavaScript:script completionHandler:completionHandler];
}

- (void)load
{
//  [_webView.configuration.userContentController removeAllUserScripts];
  [_webView.configuration.userContentController addUserScript:[self _termInitScript]];
  
  NSString *path = [[NSBundle mainBundle] pathForResource:@"term" ofType:@"html"];
  NSURL *url = [NSURL fileURLWithPath:path];
  NSURLRequest *request = [NSURLRequest requestWithURL:url];
  
  [_webView loadRequest:request];
}

- (void)reload
{
  [_webView.configuration.userContentController removeAllUserScripts];
  [_webView.configuration.userContentController addUserScript:[self _termInitScript]];
  [_webView reload];
}

- (void)setWidth:(NSInteger)count
{
  [self _evalJS:term_setWidth(count) completionHandler:nil];
}

- (void)setFontSize:(NSNumber *)newSize
{
  [self _evalJS:term_setFontSize(newSize) completionHandler:nil];
}

- (void)clear
{
  [self _evalJS:term_clear() completionHandler:nil];
}

- (void)cleanSelection
{
  [self _evalJS:term_cleanSelection() completionHandler:nil];
}

- (void)setCursorBlink:(BOOL)state
{
  [self _evalJS:term_setCursorBlink(state) completionHandler:nil];
}

- (void)reset
{
  [self _evalJS:term_reset() completionHandler:nil];
}

- (void)increaseFontSize
{
  [self _evalJS:term_increaseFontSize() completionHandler:nil];
}

- (void)decreaseFontSize
{
  [self _evalJS:term_decreaseFontSize() completionHandler:nil];
}

- (void)resetFontSize
{
  [self _evalJS:term_resetFontSize() completionHandler:nil];
}

- (void)focus {
  _focused = YES;
  [self _evalJS:term_focus() completionHandler:nil];
}

- (void)blur
{
  _focused = NO;
  [self _evalJS:term_blur() completionHandler:nil];
}

// Write data to terminal control
- (void)write:(NSString *)data
{
  dispatch_async(_jsQueue, ^{
    [_jsBuffer appendString:data];
    
    if (_jsIsBusy) {
      return;
    }
  
    _jsIsBusy = YES;
    
    NSString * buffer = _jsBuffer;
    _jsBuffer = [[NSMutableString alloc] init];
    
    NSString *jsScript = term_write(buffer);
    
    dispatch_async(dispatch_get_main_queue(), ^{
      [self _evalJS: jsScript completionHandler:^(id result, NSError *error) {
        dispatch_async(_jsQueue, ^{
          _jsIsBusy = NO;
          if (_jsBuffer.length > 0) {
            [self write:@""];
          }
        });
      }];
    });
    
  });
}


//  Since TermView is a WKScriptMessageHandler, it must implement the userContentController:didReceiveScriptMessage method. This is the method that is triggered each time 'interOp' is sent a message from the JavaScript code.
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  NSDictionary *sentData = (NSDictionary *)message.body;
  NSString *operation = sentData[@"op"];
  NSDictionary *data = sentData[@"data"];

  if ([operation isEqualToString:@"sigwinch"]) {
    if ([_termDelegate respondsToSelector:@selector(updateTermRows:Cols:)]) {
      [_termDelegate updateTermRows:data[@"rows"] Cols:data[@"cols"]];
    }
  } else if ([operation isEqualToString:@"terminalReady"]) {
    if ([_termDelegate respondsToSelector:@selector(terminalIsReady:)]) {
      [_termDelegate terminalIsReady:data[@"size"]];
      _webView.frame = self.bounds;
      _webView.scrollView.contentInset = UIEdgeInsetsZero;
      _webView.scrollView.contentSize = self.bounds.size;
      
      if (_focused) {
        [self focus];
      } else {
        [self blur];
      }
    }
  } else if ([operation isEqualToString:@"fontSizeChanged"]) {
    if ([_termDelegate respondsToSelector:@selector(fontSizeChanged:)]) {
      [_termDelegate fontSizeChanged:data[@"size"]];
    }
  } else if ([operation isEqualToString:@"copy"]) {
    [[UIPasteboard generalPasteboard] setString:data[@"content"]];
  }
}


- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(nonnull UIGestureRecognizer *)otherGestureRecognizer
{
  if (gestureRecognizer == _pinchGesture && [otherGestureRecognizer isKindOfClass:[UISwipeGestureRecognizer class]]) {
    return YES;
  }
  return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
  if (gestureRecognizer == _tapBackground && [otherGestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]) {
    // We cancel the one from the WebView from executing, as it will wait for this one to fail.
    // We return yes, to make sure that is understood.
    [otherGestureRecognizer requireGestureRecognizerToFail:gestureRecognizer];
    return YES;
  }
  if (gestureRecognizer == _longPressBackground && [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
    return YES;
  }

  return NO;
}

- (void)longPress:(UILongPressGestureRecognizer *)gestureRecognizer
{
  if (gestureRecognizer.state != UIGestureRecognizerStateRecognized) {
    return;
  }

  
  UIMenuController *menuController = [UIMenuController sharedMenuController];

  if (menuController.isMenuVisible) {
    [menuController setMenuVisible:NO animated:YES];
  } else {
    CGPoint touchPoint = [gestureRecognizer locationInView:self];
    CGRect targetRect = CGRectMake(touchPoint.x - 10, touchPoint.y - 10, 10, 10);
    
    [self _detectLinkInSelection: ^{
      [menuController setTargetRect: targetRect inView:self];
      
      NSMutableArray *items = [[NSMutableArray alloc] init];
      
      [items addObject:[[UIMenuItem alloc] initWithTitle:@"Paste"
                                                  action:@selector(yank:)]];
      
      if (_detectedLink) {
        NSString *host = [_detectedLink host];
        [items addObject:[[UIMenuItem alloc] initWithTitle:[@"Copy " stringByAppendingString:host]
                                                    action:@selector(copyLink:)]];
        
        [items addObject:[[UIMenuItem alloc] initWithTitle:[@"Open " stringByAppendingString:host]
                                                    action:@selector(openLink:)]];
      }
      
//      [items addObject:[[UIMenuItem alloc] initWithTitle:@"Unselect"
//                                                  action:@selector(unselect:)]];
//
      [menuController setMenuItems:items];
      [menuController setMenuVisible:YES animated:YES];
    }];
  }
}

- (void)_detectLinkInSelection:(void (^)(void)) block {
  _detectedLink = nil;
  [self _evalJS:term_getCurrentSelection() completionHandler:^(id _Nullable res, NSError * _Nullable error) {
    if (error) {
      block();
      return;
    }
    _selectedText = res[@"text"];
    NSString *text = res[@"base"];
    NSInteger offset = [res[@"offset"] integerValue];
    
    if (text == nil || [text length] == 0) {
      block();
      return;
    }
    
    NSDataDetector * dataDetector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
    [dataDetector enumerateMatchesInString:text options:kNilOptions range:NSMakeRange(0, [text length])
        usingBlock:^(NSTextCheckingResult * _Nullable result, NSMatchingFlags flags, BOOL * _Nonnull stop) {
          
      if (result == nil) {
        return;
      }
      NSURL *url = result.URL;
      
      if (url && result.range.location <= offset && result.range.location + result.range.length >= offset) {
        _detectedLink = url;
        *stop = YES;
      }
    }];

    block();
  }];
}


// just to remove warning in selector

- (void)copyLink:(id)sender
{
}

- (void)openLink:(id)sender
{
}

- (void)yank:(id)sender
{
}

- (void)unselect:(id)sender
{
}

- (void)activeControl:(UITapGestureRecognizer *)gestureRecognizer
{
  if (gestureRecognizer.state != UIGestureRecognizerStateRecognized) {
    return;
  }
  
  [self cleanSelection];
  [_termDelegate focus];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gestureRecognizer
{
  if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
    [self _evalJS: term_scaleStart() completionHandler:nil];
    if (_pinchSamplingTimer) {
      [_pinchSamplingTimer invalidate];
    }

    _pinchSamplingTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(pinchSampling:) userInfo:nil repeats:YES];
    [_pinchSamplingTimer fire];
  }
  
  if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
    [_pinchSamplingTimer invalidate];    
  }
}

- (void)pinchSampling:(NSTimer *)timer
{
  [self _evalJS:term_scale(_pinchGesture.scale) completionHandler:nil];
}

- (void)copy:(id)sender
{
  [_webView copy:sender];
}

- (NSString *)_detectFontFamilyFromContent:(NSString *)content
{
  NSRegularExpression *regex = [NSRegularExpression
                                regularExpressionWithPattern:@"font-family:\\s*(.+);"
                                options:NSRegularExpressionCaseInsensitive
                                error:nil];
  __block NSString *result = nil;
  [regex enumerateMatchesInString:content
                          options:0
                            range:NSMakeRange(0, [content length])
                       usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop)
  {
    if (match && match.numberOfRanges == 2) {
     result = [content substringWithRange:[match rangeAtIndex:1]];
    }
    *stop = YES;
  }];
  return result;
}

- (WKUserScript *)_termInitScript
{
  NSMutableArray *script = [[NSMutableArray alloc] init];
  BKFont *font = [BKFont withName:[BKDefaults selectedFontName]];
  NSString *fontFamily = font.name;
  if (font && font.isCustom && font.content) {
    [script addObject:term_appendUserCss(font.content)];
    fontFamily = [self _detectFontFamilyFromContent:font.content] ?: font.name;
  }
  
  [script addObject:@"function applyUserSettings() {"];
  {
    if (fontFamily) {
      [script addObject: term_setFontFamily(fontFamily)];
    }
    
    BKTheme *theme = [BKTheme withName:[BKDefaults selectedThemeName]];
    if (theme) {
      [script addObject:theme.content];
    }
    
    [script addObject:term_setFontSize([BKDefaults selectedFontSize])];
    
    [script addObject: term_setCursorBlink([BKDefaults isCursorBlink])];
  }
  [script addObject:@"};"];

  [script addObject:term_init()];

  return [[WKUserScript alloc] initWithSource:
          [script componentsJoinedByString:@"\n"]
                                injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                             forMainFrameOnly:YES];
}

- (void)terminate
{
  // Disconnect message handler
  [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"interOp"];
}

@end
