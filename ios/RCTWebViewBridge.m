/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * Copyright (c) 2015-present, Ali Najafizadeh (github.com/alinz)
 * All rights reserved
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTWebViewBridge.h"

#import <UIKit/UIKit.h>

#import <React/RCTAutoInsetsProtocol.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/RCTView.h>
#import "UIView+React.h"

// #import <React/UIView+React.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>

//This is a very elegent way of defining multiline string in objective-c.
//source: http://stackoverflow.com/a/23387659/828487
#define NSStringMultiline(...) [[NSString alloc] initWithCString:#__VA_ARGS__ encoding:NSUTF8StringEncoding]

//we don'e need this one since it has been defined in RCTWebView.m
//NSString *const RCTJSNavigationScheme = @"react-js-navigation";
NSString *const RCTWebViewBridgeSchema = @"wvb";

// runtime trick to remove UIWebview keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelper : NSObject @end
@implementation _SwizzleHelper
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface RCTWebViewBridge () <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, RCTAutoInsetsProtocol>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onBridgeMessage;

@end

@implementation RCTWebViewBridge
{
  WKWebView *_webView;
  NSString *_injectedJavaScript;
  bool _shouldTrackLoadingStart;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    super.backgroundColor = [UIColor clearColor];
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
    _shouldTrackLoadingStart = NO;
    [self setupWebview];
    [self addSubview:_webView];
  }
  return self;
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (void)goForward
{
  [_webView goForward];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  [_webView reload];
}

- (void)sendToBridge:(NSString *)message
{
  //we are warpping the send message in a function to make sure that if
  //WebView is not injected, we don't crash the app.
  NSString *format = NSStringMultiline(
    (function(){
      if (WebViewBridge && WebViewBridge.__push__) {
        WebViewBridge.__push__('%@');
      }
    }());
  );

  NSString *quotedMessage = [message stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
  NSString *command = [NSString stringWithFormat: format, quotedMessage];
  [_webView evaluateJavaScript:command completionHandler:^(id result, NSError * _Nullable error) {
    if (error) {
        NSLog(@"WKWebview sendToBridge evaluateJavaScript Error: %@", error);
    }
  }];
}

- (NSURL *)URL
{
  return _webView.URL;
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];

    // Check for a static html source first
    NSString *html = [RCTConvert NSString:source[@"html"]];
    if (html) {
      NSURL *baseURL = [RCTConvert NSURL:source[@"baseUrl"]];
      [_webView loadHTMLString:html baseURL:baseURL];
      return;
    }

    NSURLRequest *request = [RCTConvert NSURLRequest:source];
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page.
    if ([request.URL isEqual:_webView.URL]) {
      return;
    }
    if (!request.URL) {
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
    [_webView loadRequest:request];
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _webView.frame = self.bounds;
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = (alpha == 1.0);
  _webView.backgroundColor = backgroundColor;
}

- (UIColor *)backgroundColor
{
  return _webView.backgroundColor;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
    @"url": _webView.URL.absoluteString ?: @"",
    @"loading" : @(_webView.loading),
    @"title": _webView.title,
    @"canGoBack": @(_webView.canGoBack),
    @"canGoForward" : @(_webView.canGoForward),
  }];

  return event;
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (!hideKeyboardAccessoryView) {
    return;
  }

  UIView* subview;
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"UIWeb"])
      subview = view;
  }

  if(subview == nil) return;

  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelper", subview.class.superclass];
  Class newClass = NSClassFromString(name);

  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;

    Method method = class_getInstanceMethod([_SwizzleHelper class], @selector(inputAccessoryView));
      class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

    objc_registerClassPair(newClass);
  }

  object_setClass(subview, newClass);
}

#pragma mark - WebKit WebView Setup and JS Handler

-(void)setupWebview {
    WKWebViewConfiguration *theConfiguration = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *controller = [[WKUserContentController alloc]init];
    [controller addScriptMessageHandler:self name:@"observe"];

    [theConfiguration setUserContentController:controller];
    theConfiguration.allowsInlineMediaPlayback = NO;

    _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:theConfiguration];
    _webView.UIDelegate = self;
    _webView.navigationDelegate = self;
    _webView.allowsBackForwardNavigationGestures = true;

    [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
}

-(void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message{
  if ([message.body rangeOfString:RCTWebViewBridgeSchema].location == NSNotFound) {
    NSMutableDictionary<NSString *, id> *onBridgeMessageEvent = [[NSMutableDictionary alloc] initWithDictionary:@{
      @"messages": [self stringArrayJsonToArray: message.body]
    }];

    _onBridgeMessage(onBridgeMessageEvent);

    return;
  }

  [_webView evaluateJavaScript:@"WebViewBridge.__fetch__()" completionHandler:^(id result, NSError * _Nullable error) {
    if (!error) {
      NSMutableDictionary<NSString *, id> *onBridgeMessageEvent = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"messages": [self stringArrayJsonToArray: result]
      }];

      _onBridgeMessage(onBridgeMessageEvent);
    }
  }];
}

#pragma mark - WebKit WebView Delegate methods

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
  _shouldTrackLoadingStart = YES;
}

-(void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler{
  if (_onLoadingStart && _shouldTrackLoadingStart) {
    _shouldTrackLoadingStart = NO;
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
      @"url": (navigationAction.request.URL).absoluteString,
      @"navigationType": @(navigationAction.navigationType)
    }];
    _onLoadingStart(event);
  }

  if (_onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
      @"url": (navigationAction.request.URL).absoluteString,
      @"navigationType": @(navigationAction.navigationType)
    }];

    if (![self.delegate webView:self shouldStartLoadForRequest:event withCallback:_onShouldStartLoadWithRequest]) {
      decisionHandler(WKNavigationActionPolicyCancel);
    }else{
      decisionHandler(WKNavigationActionPolicyAllow);
    }
  }
  decisionHandler(WKNavigationActionPolicyAllow);
}

-(void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
      @"domain": error.domain,
      @"code": @(error.code),
      @"description": error.localizedDescription,
    }];
    _onLoadingError(event);
  }
}

-(void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation{
  NSString *webViewBridgeScriptContent = [self webViewBridgeScript];
  [webView evaluateJavaScript:webViewBridgeScriptContent completionHandler:^(id webviewScriptResult, NSError * _Nullable webviewScriptError) {
    if (webviewScriptError) {
      NSLog(@"WKWebview sendToBridge evaluateJavaScript Error: %@", webviewScriptError);
      return;
    }

    if (_injectedJavaScript != nil) {
      [webView evaluateJavaScript:_injectedJavaScript completionHandler:^(id result, NSError * _Nullable error) {
        NSString *jsEvaluationValue = (NSString *) result;
        NSMutableDictionary<NSString *, id> *event = [self baseEvent];
        event[@"jsEvaluationValue"] = jsEvaluationValue;
        if (_onLoadingFinish) {
          _onLoadingFinish(event);
        }
      }];
    } else if (_onLoadingFinish) {
      _onLoadingFinish([self baseEvent]);
    }
  }];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{

  if (!navigationAction.targetFrame.isMainFrame) {
    [webView loadRequest:navigationAction.request];
  }

  return nil;
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)())completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        completionHandler();
    }]];
    
    UIViewController *viewController = [[[[UIApplication sharedApplication] delegate] window] rootViewController];
    if ( viewController.presentedViewController && !viewController.presentedViewController.isBeingDismissed ) {
        viewController = viewController.presentedViewController;
    }

    NSLayoutConstraint *constraint = [NSLayoutConstraint 
    constraintWithItem:alert.view 
    attribute:NSLayoutAttributeHeight 
    relatedBy:NSLayoutRelationLessThanOrEqual 
    toItem:nil 
    attribute:NSLayoutAttributeNotAnAttribute 
    multiplier:1 
    constant:viewController.view.frame.size.height*2.0f];

    [alert.view addConstraint:constraint];
    [viewController presentViewController:alert animated:YES completion:^{}];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        completionHandler(NO);
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        completionHandler(YES);
    }]];
    
    UIViewController *viewController = [[[[UIApplication sharedApplication] delegate] window] rootViewController];
    if ( viewController.presentedViewController && !viewController.presentedViewController.isBeingDismissed ) {
        viewController = viewController.presentedViewController;
    }

    NSLayoutConstraint *constraint = [NSLayoutConstraint 
    constraintWithItem:alert.view 
    attribute:NSLayoutAttributeHeight 
    relatedBy:NSLayoutRelationLessThanOrEqual 
    toItem:nil 
    attribute:NSLayoutAttributeNotAnAttribute 
    multiplier:1 
    constant:viewController.view.frame.size.height*2.0f];

    [alert.view addConstraint:constraint];
    [viewController presentViewController:alert animated:YES completion:^{}];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *result))completionHandler
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:prompt
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = prompt;
        textField.secureTextEntry = NO;
        textField.text = defaultText;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        completionHandler(nil);
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        completionHandler([alert.textFields.firstObject text]);
    }]];
    
    UIViewController *viewController = [[[[UIApplication sharedApplication] delegate] window] rootViewController];
    if ( viewController.presentedViewController && !viewController.presentedViewController.isBeingDismissed ) {
        viewController = viewController.presentedViewController;
    }

    NSLayoutConstraint *constraint = [NSLayoutConstraint 
    constraintWithItem:alert.view 
    attribute:NSLayoutAttributeHeight 
    relatedBy:NSLayoutRelationLessThanOrEqual 
    toItem:nil 
    attribute:NSLayoutAttributeNotAnAttribute 
    multiplier:1 
    constant:viewController.view.frame.size.height*2.0f];

    [alert.view addConstraint:constraint];
    [viewController presentViewController:alert animated:YES completion:^{}];
}

#pragma mark - WebviewBridge helpers

- (NSArray*)stringArrayJsonToArray:(NSString *)message
{
  return [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                         options:NSJSONReadingAllowFragments
                                           error:nil];
}

//since there is no easy way to load the static lib resource in ios,
//we are loading the script from this method.
- (NSString *)webViewBridgeScript {
  NSBundle *bundle = [NSBundle mainBundle];
  NSString *webViewBridgeScriptFile = [bundle pathForResource:@"notescorebridge"
                                                       ofType:@"js"];
  NSString *webViewBridgeScriptContent = [NSString stringWithContentsOfFile:webViewBridgeScriptFile
                                                                   encoding:NSUTF8StringEncoding
                                                                      error:nil];
  return webViewBridgeScriptContent;
}

@end
