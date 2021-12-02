//
//  MAScanTACViewController.h
//

@import AVFoundation;

#import "MAPax.h"
#import "MAPaxViewController.h"
#import "MABasicScannerViewController.h"

@interface MAScanTACViewController : MABasicScannerViewController <AVCaptureMetadataOutputObjectsDelegate>

@property (nonatomic, strong) MAPax *pax;
@property (nonatomic, assign) id<MAPaxScanTACDelegate> paxScanTACDelegate;

@end
