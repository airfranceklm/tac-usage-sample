//
//  MAScanTACViewController.m
//

#import "MAScanTACViewController.h"

#import "NSBundle+Marco.h"
#import "TacVerifSdk/TacVerifSdk-Swift.h"

int const SCAN_WIDTH_TAC   = 250;
int const SCAN_HEIGHT_TAC  = 250;

@interface MAScanTACViewController ()

@property (nonatomic, weak) IBOutlet UIView *overlay;

@end


@implementation MAScanTACViewController


#pragma mark - View lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self tacSetup];
}

- (void)viewDidAppear:(BOOL)animated {
    [self initScanViewWithWidth:SCAN_WIDTH_TAC height:SCAN_HEIGHT_TAC marginTop:0];

    [super viewDidAppear:animated];
        
    if ([TacVerifSdk.instance isSyncNeeded]) {
        self.requestBeginDate = [NSDate date];
        [self showHUDWithTitle:NSLocalizedString(@"TAC_SYNC", @"Synchronizing") cancellable:false];
        
        [TacVerifSdk.instance synchronizeLatestCertificatesWithCompletion:^(TacVerifSdkNSError * _Nullable error) {
            if (error == nil && TacVerifSdk.instance.canAnalyzeCodes) {
                // Sync OK - scan possible
                [self hideHUD];
                self.shouldActivateScanner = true;
            } else {
                // Sync ERROR - scan impossible
                self.shouldActivateScanner = false;
                [self showErrorHUDWithTitle:NSLocalizedString(@"TAC_SYNC_ERROR", @"Sync error") duration:2. completion:^{
                    [self dismissViewControllerAnimated:true completion:nil];
                }];
            }
        }];
    }
}


#pragma mark - IBActions

- (IBAction)tapOnClose {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}


#pragma mark - Helpers

- (void)activateScanner {
    self.shouldActivateScanner = true;
}


#pragma mark - Superclass implementation

- (void)configureMetadataOutput:(AVCaptureMetadataOutput *)metadataOutput {
    metadataOutput.rectOfInterest = CGRectMake((self.view.frame.size.width-SCAN_WIDTH_TAC)/(2*self.view.frame.size.width),
                                               (self.view.frame.size.height-SCAN_HEIGHT_TAC)/(2*self.view.frame.size.height),
                                               SCAN_WIDTH_TAC/self.view.frame.size.width,
                                               SCAN_HEIGHT_TAC/self.view.frame.size.height);

    
    [metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    [metadataOutput setMetadataObjectTypes:@[AVMetadataObjectTypeQRCode, AVMetadataObjectTypeDataMatrixCode]];
}


#pragma mark - AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    
    if ((!self.presentedViewController) && (self.shouldActivateScanner)) {
        for (AVMetadataObject *metadataObject in metadataObjects) {
            
            AVMetadataMachineReadableCodeObject *readableObject = (AVMetadataMachineReadableCodeObject *)metadataObject;
            NSString *barcodeContent = readableObject.stringValue;
            
            if ([metadataObject.type isEqualToString:AVMetadataObjectTypeQRCode] || [metadataObject.type isEqualToString:AVMetadataObjectTypeDataMatrixCode]) {
                self.shouldActivateScanner = false;

                if (barcodeContent.length >= 0) {
                    // Scan OK, proceed
                    [self playSound];
                    CovidBarcodeAnalyzeResult *result = [TacVerifSdk.instance analyzeWithCode:barcodeContent];
                    [self showScanResultPopup:result];
                } else {
                    // Empty scan, retry available
                    [self showErrorHUDWithTitle:NSLocalizedString(@"TAC_SCAN_UNRECOGNIZED_CODE", @"") duration:2. completion:^{
                        [self performSelector:@selector(activateScanner) withObject:nil];
                    }];
                }
            } else {
                // Unsupported code type, scan cancelled
                [self showHUDWithTitle:NSLocalizedString(@"TAC_SCAN_UNRECOGNIZED_CODE", @"") duration:2. completion:^{
                    [self performSelector:@selector(activateScanner) withObject:nil];
                }];
            }
        }
    }
}


#pragma mark - TAC

- (void)tacSetup {
    NSDictionary *tacConfig = [NSBundle tacPlistContent];
    
    NSString *accessToken = tacConfig[@"accessToken"];
    NSString *baseUrl = tacConfig[@"baseUrl"];
    NSString *basePath = tacConfig[@"basePath"];
    NSString *synchroPath = tacConfig[@"synchroPath"];
    NSString *statsPath = tacConfig[@"statsPath"];
    BOOL synchronizeCertificates = [tacConfig[@"synchronizeCertificates"] boolValue];
    
    TacVerifSdkConf *conf = [[TacVerifSdkConf alloc] initWithAccessToken:accessToken baseUrl:baseUrl basePath:basePath synchroPath:synchroPath statsPath:statsPath synchronizeCertificates:synchronizeCertificates];
    
    [TacVerifSdk setupWith:conf];
}


#pragma mark - Scan management

- (BOOL)isPaxConcordant:(CertificateOwnerInformation *)scanedOwnerInformation {
    NSString *scanFirstName = [NSString stringByTrimmingSpecialCharacters:[NSString emptyStringIfNil:scanedOwnerInformation.firstName]];
    NSString *scanLastName  = [NSString stringByTrimmingSpecialCharacters:[NSString emptyStringIfNil:scanedOwnerInformation.name]];
    
    NSString *paxFirstName  = [NSString stringByTrimmingSpecialCharacters:[NSString emptyStringIfNil:self.pax.firstName]];
    NSString *paxLastName   = [NSString stringByTrimmingSpecialCharacters:[NSString emptyStringIfNil:self.pax.lastName]];
    
    if (![scanFirstName localizedStandardContainsString:paxFirstName] && ![paxFirstName localizedStandardContainsString:scanFirstName]) {
        return false;
    }

    if (![scanLastName localizedStandardContainsString:paxLastName] && ![paxLastName localizedStandardContainsString:scanLastName]) {
        return false;
    }
    
    if (self.pax.birthDate) {
        NSDate *scanBirthDate = [NSDate new];
        NSDate *paxBirthDate = [NSDate new];
        
        // NOTE: We receive a basic STRING for the date of birth, which is an issue regarding local time and time zones
        // We might be able to improve this process with "V2" if we obtain a more complete DATE instead
        
        // Check if date is of type dd/MM/yyyy
        NSDateFormatter *dateFormatter = [NSDateFormatter fullDateDateFormatter];
        paxBirthDate = [dateFormatter dateFromString:[dateFormatter stringFromDate:self.pax.birthDate]];
        scanBirthDate = [dateFormatter dateFromString:scanedOwnerInformation.birthDate];
        if (scanBirthDate == nil) {
            // Check if date is of type yyyy-MM-dd
            dateFormatter = [NSDateFormatter apiDateFormatter];
            scanBirthDate = [dateFormatter dateFromString:scanedOwnerInformation.birthDate];
            paxBirthDate = [dateFormatter dateFromString:[dateFormatter stringFromDate:self.pax.birthDate]];
            if (scanBirthDate == nil) {
                // Check if date is of type yyyy-MM-dd'T'HH:mm:ss
                dateFormatter = [NSDateFormatter capiDateFormatter];
                scanBirthDate = [dateFormatter dateFromString:scanedOwnerInformation.birthDate];
                paxBirthDate = [dateFormatter dateFromString:[dateFormatter stringFromDate:self.pax.birthDate]];
                if (scanBirthDate == nil) {
                    // Check if date is of type yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ
                    dateFormatter = [NSDateFormatter happyOrNotDateFormatter];
                    scanBirthDate = [dateFormatter dateFromString:scanedOwnerInformation.birthDate];
                    paxBirthDate = [dateFormatter dateFromString:[dateFormatter stringFromDate:self.pax.birthDate]];
                    if (scanBirthDate == nil) {
                        // At this point we assume that we cannot compare the dates
                        return false;
                    }
                }
            }
        }
        if (![scanBirthDate isEqualToDate:paxBirthDate]) {
            return false;
        }
    }
    
    return true;
}


#pragma mark - Popups

- (void)showScanResultPopup:(CovidBarcodeAnalyzeResult *)scanResult {
    // Check if pass is valid && not on blacklist
    if (scanResult.isValid && scanResult.administratorInformation == nil) {
        // Pass is valid: check if passenger is concordant
        if ([self isPaxConcordant:scanResult.ownerInformation]) {
            [self showConcordancePopup];
        } else {
            [self showMismatchPopup:scanResult];
        }
    } else {
        [self showInvalidPopup:scanResult];
    }
}

- (void)showConcordancePopup {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_TITLE", @"Check result") message:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_MESSAGE_CONFIRM", @"Check result valid") preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *validateAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", @"") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:true completion:^{
            // Network call towards Air France server/backend for the SK CLRD remark
            // Note that no data from the pass is transmitted
            [self.paxScanTACDelegate validateScan];
        }];
    }];
    [alertController addAction:validateAction];
    
    [self presentViewController:alertController animated:true completion:nil];
}

- (void)showMismatchPopup:(CovidBarcodeAnalyzeResult *)scanResult {
    CertificateOwnerInformation *scanedOwnerInformation = scanResult.ownerInformation;
    
    NSString *paxBirthDate = @"";
    NSString *scanBirthDate = @"";
    
    if (self.pax.birthDate) {
        NSDateFormatter *dateFormatter = [NSDateFormatter fullDateDateFormatter];
        paxBirthDate = [dateFormatter stringFromDate:self.pax.birthDate];
        scanBirthDate = [NSString emptyStringIfNil:scanedOwnerInformation.birthDate];
    }
    
    NSString *messageToFill = NSLocalizedString(@"TAC_POPUP_CONCORDANCE_KO_MESSAGE", @"Check result valid");
    if (scanResult.administratorInformation != nil) {
        messageToFill = NSLocalizedString(@"TAC_POPUP_CONCORDANCE_KO_MESSAGE_BLACKLIST", @"Check result valid (and blacklist)");
    }
    NSString *popupMessage = [NSString stringWithFormat:messageToFill,
                              [NSString emptyStringIfNil:scanedOwnerInformation.firstName.capitalizedString],
                              [NSString emptyStringIfNil:scanedOwnerInformation.name.uppercaseString],
                              scanBirthDate,
                              [NSString emptyStringIfNil:self.pax.firstName.capitalizedString],
                              [NSString emptyStringIfNil:self.pax.lastName.uppercaseString],
                              paxBirthDate];
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_KO_TITLE", @"Check result")
                                                                             message:popupMessage
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *validateAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"TAC_POPUP_ACTION_VALIDATE_IDENTITY", @"Validate identity") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showConfirmationPopup];
    }];
    [alertController addAction:validateAction];
    
    UIAlertAction *reScanAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"TAC_POPUP_ACTION_SCAN_AGAIN", @"Scan another document") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self performSelector:@selector(activateScanner) withObject:nil];
    }];
    [alertController addAction:reScanAction];
    
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CANCEL", @"") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:true completion:nil];
    }];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:true completion:nil];
}

- (void)showInvalidPopup:(CovidBarcodeAnalyzeResult *)scanResult {
    UIAlertController *alertController = nil;
    if (scanResult.administratorInformation == nil) {
        alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_TITLE", @"Check result") message:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_MESSAGE_NOT_VALID", @"Check result invalid") preferredStyle:UIAlertControllerStyleAlert];
    } else {
        alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_TITLE", @"Check result") message:NSLocalizedString(@"TAC_POPUP_CONCORDANCE_OK_MESSAGE_NOT_VALID_BLACKLIST", @"Check result invalid (blacklisted)") preferredStyle:UIAlertControllerStyleAlert];
    }
    
    UIAlertAction *reScanAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"TAC_POPUP_ACTION_SCAN_AGAIN", @"Scan another document") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self performSelector:@selector(activateScanner) withObject:nil];
    }];
    [alertController addAction:reScanAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CANCEL", @"") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:true completion:nil];
    }];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:true completion:nil];
}

- (void)showConfirmationPopup {
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:NSLocalizedString(@"TAC_POPUP_MANUAL_VALIDATION_CONFIRMATION_TITLE", @"Warning")
                                          message:NSLocalizedString(@"TAC_POPUP_MANUAL_VALIDATION_CONFIRMATION_MESSAGE", @"Are you sure you want to validate the pass?")
                                          preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *validateAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"TAC_POPUP_MANUAL_VALIDATION_CONFIRMATION_VALIDATE", @"Validate") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self dismissViewControllerAnimated:true completion:^{
            // Network call towards Air France server/backend for the SK CLRD remark
            // Note that no data from the pass is transmitted
            [self.paxScanTACDelegate validateScan];
        }];
    }];
    [alertController addAction:validateAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        [self performSelector:@selector(activateScanner) withObject:nil];
    }];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:true completion:nil];
}

@end
